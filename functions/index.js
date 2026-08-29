import {createHash, randomBytes, randomUUID, scryptSync, timingSafeEqual} from "node:crypto";
import {getApps, initializeApp} from "firebase-admin/app";
import {getAppCheck} from "firebase-admin/app-check";
import {getAuth} from "firebase-admin/auth";
import {getStorage} from "firebase-admin/storage";
import {FieldValue, getFirestore} from "firebase-admin/firestore";
import {onDocumentUpdated} from "firebase-functions/v2/firestore";
import {HttpsError, onCall, onRequest} from "firebase-functions/v2/https";
import {defineBoolean, defineString} from "firebase-functions/params";
import {setGlobalOptions} from "firebase-functions/v2";

if (getApps().length === 0) {
  initializeApp();
}

const auth = getAuth();
const appCheck = getAppCheck();
const db = getFirestore();
const region = "europe-west2";
const initialPlatformAdminEmail = defineString("INITIAL_PLATFORM_ADMIN_EMAIL");
// Monitor first: old Windows/web clients must not be locked out while their
// attestation provider is being registered and verified.
const requireAppCheck = defineBoolean("REQUIRE_APP_CHECK", {default: false});
const supportedTimeZones = Object.freeze(Intl.supportedValuesOf("timeZone"));
const supportedTimeZoneSet = new Set(supportedTimeZones);
const supportedCurrencyCodes = Object.freeze(Intl.supportedValuesOf("currency"));
const supportedCurrencyCodeSet = new Set(supportedCurrencyCodes);
// CBRT is the official Central Bank of the Republic of Türkiye source. It
// publishes a daily XML bulletin without an API key. Its ForexBuying rate is
// an indicative starting point when a venue receives foreign physical cash;
// a manager must still review or override it at checkout.
const cbrtDailyRatesUrl = "https://www.tcmb.gov.tr/kurlar/today.xml";
const cbrtRateCacheTtlMs = 15 * 60 * 1000;
let cbrtRateCache = null;

setGlobalOptions({region, maxInstances: 10});

function callerFromCall(request) {
  if (request.auth == null) {
    throw new HttpsError("unauthenticated", "Sign in before calling this action.");
  }
  return request.auth;
}

async function isPlatformAdmin(caller) {
  if (caller.token.platformAdmin === true) return true;
  // The record is written only by this trusted Admin SDK code.  It is a safe
  // fallback when a native client has not yet received a refreshed custom
  // claim token.
  const record = await db.doc(`platformAdmins/${caller.uid}`).get();
  return record.exists;
}

async function requirePlatformAdmin(caller) {
  if (!(await isPlatformAdmin(caller))) {
    throw new HttpsError(
      "permission-denied",
      "This action is restricted to TableSide platform administrators.",
    );
  }
  return caller;
}

async function requireTenantOperationalMember(caller, tenantId) {
  const membership = await db.doc(`tenants/${tenantId}/members/${caller.uid}`).get();
  if (!membership.exists || membership.data().active === false) {
    throw new HttpsError(
      "permission-denied",
      "You do not have active access to this restaurant.",
    );
  }
  const roles = Array.isArray(membership.data().roles) ? membership.data().roles : [];
  if (!roles.some((role) => ["owner", "manager", "waiter", "cashier"].includes(role))) {
    throw new HttpsError(
      "permission-denied",
      "Your role cannot send orders to production.",
    );
  }
  return {membership: membership.data(), roles};
}

function requireObject(value) {
  if (value == null || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpsError("invalid-argument", "A data object is required.");
  }
  return value;
}

function requiredText(data, name, maxLength = 160) {
  const value = data[name];
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new HttpsError("invalid-argument", `${name} is required.`);
  }
  const text = value.trim();
  if (text.length > maxLength) {
    throw new HttpsError("invalid-argument", `${name} is too long.`);
  }
  return text;
}

// Firestore document IDs may be considerably longer than ordinary API text
// fields. Validate against Firestore's actual constraints so generated,
// auditable queue IDs are accepted without allowing a path to be injected.
function requiredDocumentId(data, name) {
  const value = requiredText(data, name, 1500);
  if (Buffer.byteLength(value, "utf8") > 1500 ||
      value.includes("/") || value === "." || value === "..") {
    throw new HttpsError("invalid-argument", `${name} is invalid.`);
  }
  return value;
}

function optionalText(data, name, maxLength = 500) {
  const value = data[name];
  if (value == null) return "";
  if (typeof value !== "string" || value.trim().length > maxLength) {
    throw new HttpsError("invalid-argument", `${name} is invalid.`);
  }
  return value.trim();
}

function receiptBusinessSnapshot(tenantData) {
  const clean = (value, maximum) => typeof value === "string"
    ? value.trim().slice(0, maximum)
    : "";
  const phoneNumbers = [];
  if (Array.isArray(tenantData?.phoneNumbers)) {
    for (const value of tenantData.phoneNumbers) {
      const phone = clean(value, 60);
      if (phone.length > 0 && !phoneNumbers.includes(phone)) {
        phoneNumbers.push(phone);
      }
      if (phoneNumbers.length === 3) break;
    }
  }
  const legacyPhone = clean(tenantData?.phone, 60);
  if (legacyPhone.length > 0 && !phoneNumbers.includes(legacyPhone) &&
      phoneNumbers.length < 3) {
    phoneNumbers.push(legacyPhone);
  }
  return {
    name: clean(tenantData?.displayName, 120) || "TABLESIDE POS",
    address: clean(tenantData?.address, 400),
    phoneNumbers,
    receiptFooter: clean(tenantData?.receiptFooter, 300),
  };
}

function requiredPositiveInteger(value, name, maximum = 1000) {
  if (!Number.isInteger(value) || value <= 0 || value > maximum) {
    throw new HttpsError("invalid-argument", `${name} must be a positive whole number.`);
  }
  return value;
}

function validProductionLine(value, index) {
  const data = requireObject(value);
  return {
    id: requiredText(data, "id", 180),
    productId: requiredText(data, "productId", 180),
    quantity: requiredPositiveInteger(data.quantity, `lines[${index}].quantity`, 100),
    variantId: optionalText(data, "variantId", 180) || null,
    modifierSelections: validModifierSelections(
      data.modifierSelections,
      `lines[${index}].modifierSelections`,
    ),
    itemNote: optionalText(data, "itemNote", 500),
  };
}

function validSplitLineAllocations(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > 100) {
    throw new HttpsError(
      "invalid-argument",
      "Select between one and 100 order lines to split.",
    );
  }
  const selectedLineIds = new Set();
  return value.map((raw, index) => {
    const allocation = requireObject(raw);
    const lineId = requiredText(allocation, "lineId", 180);
    if (selectedLineIds.has(lineId)) {
      throw new HttpsError(
        "invalid-argument",
        `splitLines[${index}] repeats an order line.`,
      );
    }
    selectedLineIds.add(lineId);
    return {
      lineId,
      quantity: requiredPositiveInteger(
        allocation.quantity,
        `splitLines[${index}].quantity`,
        100,
      ),
    };
  });
}

function validModifierSelections(value, label) {
  if (value == null) return [];
  if (!Array.isArray(value) || value.length > 20) {
    throw new HttpsError("invalid-argument", `${label} must contain up to 20 groups.`);
  }
  const groupIds = new Set();
  return value.map((raw, groupIndex) => {
    const data = requireObject(raw);
    // [data] is the individual selection object. The surrounding [label] is
    // only for diagnostics; using it as the property key accidentally looked
    // for a literal `lines[0]...groupId` key in every valid request.
    const groupId = requiredText(data, "groupId", 180);
    if (groupIds.has(groupId)) {
      throw new HttpsError("invalid-argument", `${label} contains the same group twice.`);
    }
    groupIds.add(groupId);
    if (!Array.isArray(data.optionIds) || data.optionIds.length > 50) {
      throw new HttpsError(
        "invalid-argument",
        `${label}[${groupIndex}].optionIds must contain up to 50 options.`,
      );
    }
    const optionIds = data.optionIds.map((optionId, optionIndex) => {
      if (typeof optionId !== "string" || optionId.trim().length === 0 || optionId.trim().length > 180) {
        throw new HttpsError(
          "invalid-argument",
          `${label}[${groupIndex}].optionIds[${optionIndex}] is invalid.`,
        );
      }
      return optionId.trim();
    });
    if (new Set(optionIds).size !== optionIds.length) {
      throw new HttpsError("invalid-argument", `${label} contains the same option twice.`);
    }
    return {groupId, optionIds};
  });
}

function configuredModifierGroupIds(productData) {
  const raw = productData?.modifierGroupIds;
  if (raw == null) return [];
  if (!Array.isArray(raw) || raw.length > 20) {
    throw new HttpsError("failed-precondition", "This product has an invalid modifier configuration.");
  }
  const ids = raw.map((id) => {
    if (typeof id !== "string" || id.trim().length === 0 || id.trim().length > 180) {
      throw new HttpsError("failed-precondition", "This product has an invalid modifier group.");
    }
    return id.trim();
  });
  if (new Set(ids).size !== ids.length) {
    throw new HttpsError("failed-precondition", "This product repeats a modifier group.");
  }
  return ids;
}

function configuredProductVariants(productData) {
  const raw = productData?.variants;
  if (raw == null) return [];
  if (!Array.isArray(raw) || raw.length > 30) {
    throw new HttpsError("failed-precondition", "This product has an invalid variant configuration.");
  }
  const ids = new Set();
  return raw.map((rawVariant) => {
    const variant = requireObject(rawVariant);
    // [variant] is the individual saved variant object. Read its direct
    // fields rather than diagnostic dotted paths.
    const id = requiredText(variant, "id", 180);
    const name = requiredText(variant, "name", 100);
    const priceDeltaMinor = Number(variant.priceDeltaMinor ?? 0);
    if (!Number.isSafeInteger(priceDeltaMinor) ||
        priceDeltaMinor < -100000000 || priceDeltaMinor > 100000000 || ids.has(id)) {
      throw new HttpsError("failed-precondition", "This product has an invalid variant option.");
    }
    ids.add(id);
    return {
      id,
      name,
      priceDeltaMinor,
      isAvailable: variant.isAvailable !== false,
    };
  });
}

function canonicalLineConfiguration({productData, modifierGroupsById, line}) {
  const variants = configuredProductVariants(productData);
  let variant = null;
  if (variants.length > 0) {
    if (line.variantId == null) {
      throw new HttpsError("failed-precondition", "Choose a variant for this product.");
    }
    variant = variants.find((item) => item.id === line.variantId) ?? null;
    if (variant == null || !variant.isAvailable) {
      throw new HttpsError("failed-precondition", "The selected product variant is unavailable.");
    }
  } else if (line.variantId != null) {
    throw new HttpsError("failed-precondition", "This product does not have variants.");
  }

  const configuredGroupIds = configuredModifierGroupIds(productData);
  const requestedByGroup = new Map(
    line.modifierSelections.map((selection) => [selection.groupId, selection]),
  );
  for (const requestedGroupId of requestedByGroup.keys()) {
    if (!configuredGroupIds.includes(requestedGroupId)) {
      throw new HttpsError("failed-precondition", "A selected option does not belong to this product.");
    }
  }
  const modifierSelections = [];
  for (const groupId of configuredGroupIds) {
    const group = modifierGroupsById.get(groupId);
    if (group == null || group.isAvailable === false) {
      throw new HttpsError("failed-precondition", "A required product option group is no longer available.");
    }
    const groupName = typeof group.name === "string" ? group.name.trim() : "";
    const options = Array.isArray(group.options) ? group.options : null;
    const minimum = Number(group.minimumSelections ?? 0);
    const maximum = Number(group.maximumSelections ?? options?.length ?? 0);
    if (groupName.length === 0 || options == null ||
        !Number.isInteger(minimum) || !Number.isInteger(maximum) ||
        minimum < 0 || maximum < minimum || maximum > options.length) {
      throw new HttpsError("failed-precondition", "A product option group is configured incorrectly.");
    }
    const requested = requestedByGroup.get(groupId)?.optionIds ?? [];
    if (requested.length < minimum || requested.length > maximum) {
      const countLabel = minimum === maximum
        ? `exactly ${minimum}`
        : `${minimum} to ${maximum}`;
      throw new HttpsError(
        "failed-precondition",
        `Choose ${countLabel} option${maximum === 1 ? "" : "s"} for ${groupName}.`,
      );
    }
    for (const optionId of requested) {
      const option = options.find((item) => item?.id === optionId) ?? null;
      const optionName = typeof option?.name === "string" ? option.name.trim() : "";
      const priceDeltaMinor = Number(option?.priceDeltaMinor ?? 0);
      if (option == null || option.isAvailable === false || optionName.length === 0 ||
          !Number.isSafeInteger(priceDeltaMinor) ||
          priceDeltaMinor < -100000000 || priceDeltaMinor > 100000000) {
        throw new HttpsError("failed-precondition", `The selected ${groupName} option is unavailable.`);
      }
      modifierSelections.push({
        groupId,
        groupName,
        optionId,
        optionName,
        priceDeltaMinor,
      });
    }
  }
  const priceDeltaMinor = (variant?.priceDeltaMinor ?? 0) + modifierSelections.reduce(
    (total, selection) => total + selection.priceDeltaMinor,
    0,
  );
  if (!Number.isSafeInteger(priceDeltaMinor)) {
    throw new HttpsError("failed-precondition", "The selected product options have an invalid price.");
  }
  return {
    variantId: variant?.id ?? null,
    variantName: variant?.name ?? null,
    variantPriceDeltaMinor: variant?.priceDeltaMinor ?? 0,
    modifierSelections,
    itemNote: line.itemNote,
    priceDeltaMinor,
  };
}

function productionLineDetails(line) {
  const details = [];
  if (typeof line.variantName === "string" && line.variantName.trim().length > 0) {
    details.push(line.variantName.trim());
  }
  if (Array.isArray(line.modifierSelections)) {
    for (const selection of line.modifierSelections) {
      const groupName = typeof selection?.groupName === "string" ? selection.groupName.trim() : "";
      const optionName = typeof selection?.optionName === "string" ? selection.optionName.trim() : "";
      if (groupName.length > 0 && optionName.length > 0) {
        details.push(`${groupName}: ${optionName}`);
      }
    }
  }
  if (typeof line.itemNote === "string" && line.itemNote.trim().length > 0) {
    details.push(`NOTE: ${line.itemNote.trim()}`);
  }
  return details;
}

function requiredNonNegativeInteger(value, label, maximum = 100000000) {
  if (!Number.isInteger(value) || value < 0 || value > maximum) {
    throw new HttpsError(
      "invalid-argument",
      `${label} must be a whole number from 0 to ${maximum}.`,
    );
  }
  return value;
}

function requiredFiniteNumber(value, label, minimum, maximum) {
  if (typeof value !== "number" || !Number.isFinite(value) ||
      value < minimum || value > maximum) {
    throw new HttpsError(
      "invalid-argument",
      `${label} must be between ${minimum} and ${maximum}.`,
    );
  }
  return value;
}

function requiredStringArray(value, label, maximum, itemMaximum = 180) {
  if (!Array.isArray(value) || value.length > maximum ||
      value.some((item) => typeof item !== "string" ||
        item.trim().length === 0 || item.trim().length > itemMaximum)) {
    throw new HttpsError("invalid-argument", `${label} is invalid.`);
  }
  return [...new Set(value.map((item) => item.trim()))];
}

function requiredDocumentIdArray(value, label, maximum) {
  const ids = requiredStringArray(value, label, maximum, 1500);
  if (ids.some((id) => Buffer.byteLength(id, "utf8") > 1500 ||
      id.includes("/") || id === "." || id === "..")) {
    throw new HttpsError("invalid-argument", `${label} contains an invalid document ID.`);
  }
  return ids;
}

function validatedVariants(value) {
  if (!Array.isArray(value) || value.length > 30) {
    throw new HttpsError("invalid-argument", "A product can have at most 30 variants.");
  }
  const ids = new Set();
  const names = new Set();
  return value.map((raw) => {
    const variant = requireObject(raw);
    const id = requiredText(variant, "id", 180);
    const name = requiredText(variant, "name", 80);
    const priceDeltaMinor = variant.priceDeltaMinor;
    if (!Number.isInteger(priceDeltaMinor) || Math.abs(priceDeltaMinor) > 100000000 ||
        ids.has(id) || names.has(name.toLowerCase())) {
      throw new HttpsError("invalid-argument", "A product variant is invalid or duplicated.");
    }
    ids.add(id);
    names.add(name.toLowerCase());
    return {id, name, priceDeltaMinor, isAvailable: variant.isAvailable !== false};
  });
}

function validatedModifierOptions(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > 50) {
    throw new HttpsError("invalid-argument", "Add between one and 50 modifier options.");
  }
  const ids = new Set();
  const names = new Set();
  return value.map((raw) => {
    const option = requireObject(raw);
    const id = requiredText(option, "id", 180);
    const name = requiredText(option, "name", 80);
    const priceDeltaMinor = option.priceDeltaMinor;
    if (!Number.isInteger(priceDeltaMinor) || Math.abs(priceDeltaMinor) > 100000000 ||
        ids.has(id) || names.has(name.toLowerCase())) {
      throw new HttpsError("invalid-argument", "A modifier option is invalid or duplicated.");
    }
    ids.add(id);
    names.add(name.toLowerCase());
    return {id, name, priceDeltaMinor, isAvailable: option.isAvailable !== false};
  });
}

async function manageMenuConfigurationFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const resource = requiredText(data, "resource", 32);
  const operation = requiredText(data, "operation", 32);
  const values = data.values == null ? {} : requireObject(data.values);
  const documentId = data.documentId == null || data.documentId === ""
    ? null
    : requiredDocumentId(data, "documentId");
  const {roles} = await requireTenantOperationalMember(caller, tenantId);
  if (!roles.some((role) => role === "owner" || role === "manager")) {
    throw new HttpsError("permission-denied", "Only a manager can change the menu.");
  }
  const venue = await db.doc(`tenants/${tenantId}/venues/${venueId}`).get();
  if (!venue.exists || venue.data().status === "deleting") {
    throw new HttpsError("failed-precondition", "The selected venue is not active.");
  }
  const collectionNames = {
    section: "menuSections",
    product: "products",
    modifierGroup: "modifierGroups",
    taxRate: "taxRates",
  };
  const collectionName = collectionNames[resource];
  if (collectionName == null) {
    throw new HttpsError("invalid-argument", "That menu resource is not supported.");
  }
  const collection = db.collection(`tenants/${tenantId}/${collectionName}`);
  const reference = documentId == null ? collection.doc() : collection.doc(documentId);
  const actor = actorSnapshot(await auth.getUser(caller.uid));

  if (operation === "delete") {
    if (documentId == null) {
      throw new HttpsError("invalid-argument", "documentId is required for deletion.");
    }
    const current = await reference.get();
    if (!current.exists || current.data().venueId !== venueId) {
      throw new HttpsError("not-found", "That menu record was not found at this venue.");
    }
    if (resource === "section") {
      const [children, products] = await Promise.all([
        collection.where("parentSectionId", "==", documentId).get(),
        db.collection(`tenants/${tenantId}/products`)
          .where("sectionIds", "array-contains", documentId).get(),
      ]);
      if (children.docs.some((item) => item.data().venueId === venueId) ||
          products.docs.some((item) => item.data().venueId === venueId)) {
        throw new HttpsError("failed-precondition", "Move linked subcategories and products before deleting this section.");
      }
    }
    if (resource === "modifierGroup") {
      const products = await db.collection(`tenants/${tenantId}/products`)
        .where("modifierGroupIds", "array-contains", documentId).get();
      if (products.docs.some((item) => item.data().venueId === venueId)) {
        throw new HttpsError("failed-precondition", "Remove this option group from its products before deleting it.");
      }
    }
    if (resource === "taxRate") {
      const products = await db.collection(`tenants/${tenantId}/products`)
        .where("taxRateId", "==", documentId).get();
      if (products.docs.some((item) => item.data().venueId === venueId)) {
        throw new HttpsError("failed-precondition", "Assign another tax rate to its products before deleting it.");
      }
    }
    await reference.delete();
    await writeAudit(caller.uid, "deleteMenuConfiguration", documentId, {
      tenantId, venueId, resource, actor,
    });
    return {documentId, deleted: true};
  }

  if (operation === "availability") {
    if (resource !== "product" || documentId == null || typeof values.isAvailable !== "boolean") {
      throw new HttpsError("invalid-argument", "A valid product availability change is required.");
    }
    const current = await reference.get();
    if (!current.exists || current.data().venueId !== venueId) {
      throw new HttpsError("not-found", "That product was not found at this venue.");
    }
    await reference.update({
      isAvailable: values.isAvailable,
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    });
    return {documentId, updated: true};
  }

  if (operation !== "save") {
    throw new HttpsError("invalid-argument", "That menu operation is not supported.");
  }
  if (documentId != null) {
    const current = await reference.get();
    if (!current.exists || current.data().venueId !== venueId) {
      throw new HttpsError("not-found", "That menu record was not found at this venue.");
    }
  }

  let cleaned;
  if (resource === "section") {
    const rawParentSectionId = optionalText(values, "parentSectionId", 1500);
    const parentSectionId = rawParentSectionId
      ? requiredDocumentId({parentSectionId: rawParentSectionId}, "parentSectionId")
      : null;
    if (parentSectionId === documentId) {
      throw new HttpsError("invalid-argument", "A section cannot be its own parent.");
    }
    if (parentSectionId != null) {
      const parent = await collection.doc(parentSectionId).get();
      if (!parent.exists || parent.data().venueId !== venueId) {
        throw new HttpsError("failed-precondition", "The selected parent section is not available at this venue.");
      }
    }
    cleaned = {
      name: requiredText(values, "name", 80),
      icon: optionalText(values, "icon", 20) || "🍽️",
      parentSectionId,
      ...(documentId == null
        ? {sortOrder: requiredNonNegativeInteger(values.sortOrder, "sortOrder", 100000)}
        : {}),
    };
  } else if (resource === "modifierGroup") {
    const options = validatedModifierOptions(values.options);
    const minimumSelections = requiredNonNegativeInteger(
      values.minimumSelections, "minimumSelections", options.length,
    );
    const maximumSelections = requiredNonNegativeInteger(
      values.maximumSelections, "maximumSelections", options.length,
    );
    if (maximumSelections < minimumSelections) {
      throw new HttpsError("invalid-argument", "Modifier selection limits are invalid.");
    }
    cleaned = {
      name: requiredText(values, "name", 80),
      minimumSelections,
      maximumSelections,
      options,
      ...(documentId == null ? {isAvailable: true} : {}),
    };
  } else if (resource === "taxRate") {
    const name = requiredText(values, "name", 80);
    const basisPoints = requiredNonNegativeInteger(values.basisPoints, "basisPoints", 100000);
    const duplicates = await collection.get();
    if (duplicates.docs.some((item) => item.id !== documentId &&
        item.data().venueId === venueId &&
        String(item.data().name ?? "").trim().toLowerCase() === name.toLowerCase())) {
      throw new HttpsError("already-exists", "A tax rate with this name already exists at this venue.");
    }
    cleaned = {name, basisPoints, ...(documentId == null ? {active: true} : {})};
  } else {
    const sectionIds = requiredDocumentIdArray(values.sectionIds, "sectionIds", 20);
    if (sectionIds.length === 0) {
      throw new HttpsError("invalid-argument", "Select at least one menu section.");
    }
    const modifierGroupIds = requiredDocumentIdArray(
      values.modifierGroupIds ?? [], "modifierGroupIds", 20,
    );
    const linkedIds = [...sectionIds, ...modifierGroupIds];
    const linkedReferences = [
      ...sectionIds.map((id) => db.doc(`tenants/${tenantId}/menuSections/${id}`)),
      ...modifierGroupIds.map((id) => db.doc(`tenants/${tenantId}/modifierGroups/${id}`)),
    ];
    const linked = linkedReferences.length === 0
      ? []
      : await db.getAll(...linkedReferences);
    if (linked.some((item, index) => !item.exists ||
        item.data().venueId !== venueId || item.id !== linkedIds[index])) {
      throw new HttpsError("failed-precondition", "A selected section or option group is not available at this venue.");
    }
    const productionArea = requiredText(values, "productionArea", 32);
    if (!["bar", "kitchen", "dessert"].includes(productionArea)) {
      throw new HttpsError("invalid-argument", "The product production area is invalid.");
    }
    const trackStock = values.trackStock === true;
    const rawTaxRateId = optionalText(values, "taxRateId", 1500);
    const taxRateId = rawTaxRateId
      ? requiredDocumentId({taxRateId: rawTaxRateId}, "taxRateId")
      : null;
    let taxRateName = requiredText(values, "taxRateName", 80);
    let taxRateBasisPoints = requiredNonNegativeInteger(
      values.taxRateBasisPoints, "taxRateBasisPoints", 100000,
    );
    if (taxRateId != null) {
      const taxRate = await db.doc(`tenants/${tenantId}/taxRates/${taxRateId}`).get();
      if (!taxRate.exists || taxRate.data().venueId !== venueId) {
        throw new HttpsError("failed-precondition", "The selected tax rate is not available at this venue.");
      }
      taxRateName = requiredText(taxRate.data(), "name", 80);
      taxRateBasisPoints = requiredNonNegativeInteger(
        taxRate.data().basisPoints, "basisPoints", 100000,
      );
    }
    cleaned = {
      name: requiredText(values, "name", 120),
      priceMinor: requiredNonNegativeInteger(values.priceMinor, "priceMinor"),
      sectionIds,
      productionArea,
      trackStock,
      stockOnHand: trackStock
        ? requiredFiniteNumber(values.stockOnHand ?? 0, "stockOnHand", -1000000000, 1000000000)
        : null,
      stockPerSale: requiredFiniteNumber(values.stockPerSale, "stockPerSale", 0.000001, 1000000000),
      ...(documentId == null ? {stockUnit: "each", isAvailable: true} : {}),
      showOnOrderFlow: values.showOnOrderFlow === true,
      taxRateBasisPoints,
      taxRateId,
      taxRateName,
      variants: validatedVariants(values.variants ?? []),
      modifierGroupIds,
    };
  }

  const writeData = {
    ...cleaned,
    ...(documentId == null ? {venueId, createdAt: FieldValue.serverTimestamp()} : {}),
    updatedAt: FieldValue.serverTimestamp(),
    updatedByActor: actor,
  };
  await reference.set(writeData, {merge: documentId != null});
  if (resource === "taxRate" && documentId != null) {
    const products = await db.collection(`tenants/${tenantId}/products`)
      .where("taxRateId", "==", documentId).get();
    const writer = db.bulkWriter();
    for (const product of products.docs.filter((item) => item.data().venueId === venueId)) {
      writer.update(product.ref, {
        taxRateName: cleaned.name,
        taxRateBasisPoints: cleaned.basisPoints,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    await writer.close();
  }
  await writeAudit(caller.uid, "saveMenuConfiguration", reference.id, {
    tenantId, venueId, resource, operation: documentId == null ? "create" : "update", actor,
  });
  return {documentId: reference.id, saved: true};
}

async function manageVenueConfigurationFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const resource = requiredText(data, "resource", 32);
  const values = requireObject(data.values);
  const {roles} = await requireTenantOperationalMember(caller, tenantId);
  if (!roles.some((role) => role === "owner" || role === "manager")) {
    throw new HttpsError("permission-denied", "Only a manager can change venue configuration.");
  }
  const venue = await db.doc(`tenants/${tenantId}/venues/${venueId}`).get();
  if (!venue.exists || venue.data().status === "deleting") {
    throw new HttpsError("failed-precondition", "The selected venue is not active.");
  }
  const actor = actorSnapshot(await auth.getUser(caller.uid));

  if (resource === "tenantProfile") {
    const phoneNumbers = requiredStringArray(
      values.phoneNumbers ?? [], "phoneNumbers", 3, 40,
    );
    const logoUrl = optionalText(values, "logoUrl", 2000) || null;
    await db.doc(`tenants/${tenantId}`).set({
      displayName: requiredText(values, "displayName", 120),
      legalName: optionalText(values, "legalName", 160),
      address: optionalText(values, "address", 500),
      phone: phoneNumbers[0] ?? "",
      phoneNumbers,
      receiptFooter: optionalText(values, "receiptFooter", 300),
      logoUrl,
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    }, {merge: true});
  } else if (resource === "printerDevice") {
    const deviceId = requiredDocumentId(values, "deviceId");
    const productionAreas = requiredStringArray(
      values.productionAreas, "productionAreas", 4, 32,
    );
    const transports = requiredStringArray(values.transports, "transports", 4, 40);
    if (productionAreas.some((area) =>
      !["bar", "kitchen", "dessert", "receipt"].includes(area)) ||
        transports.some((transport) =>
          !["bluetooth", "windowsPrintQueue", "builtIn"].includes(transport))) {
      throw new HttpsError("invalid-argument", "The printer capabilities are invalid.");
    }
    await db.doc(`tenants/${tenantId}/devices/${deviceId}`).set({
      venueId,
      name: requiredText(values, "name", 120),
      platform: requiredText(values, "platform", 32),
      productionAreas,
      transports,
      assignedUserId: caller.hostUid ?? caller.uid,
      active: values.active !== false,
      registeredAt: FieldValue.serverTimestamp(),
      lastHeartbeatAt: FieldValue.serverTimestamp(),
      registeredByActor: actor,
    }, {merge: true});
  } else if (resource === "printerRoute") {
    const productionArea = requiredText(values, "productionArea", 32);
    if (!["bar", "kitchen", "dessert", "receipt"].includes(productionArea)) {
      throw new HttpsError("invalid-argument", "The printer production area is invalid.");
    }
    const rawPrimary = optionalText(values, "primaryDeviceId", 1500);
    const rawFallback = optionalText(values, "fallbackDeviceId", 1500);
    const primaryDeviceId = rawPrimary
      ? requiredDocumentId({primaryDeviceId: rawPrimary}, "primaryDeviceId")
      : null;
    const fallbackDeviceId = rawFallback
      ? requiredDocumentId({fallbackDeviceId: rawFallback}, "fallbackDeviceId")
      : null;
    if (primaryDeviceId == null && fallbackDeviceId != null) {
      throw new HttpsError("invalid-argument", "Choose a primary printer before a fallback.");
    }
    if (primaryDeviceId != null && primaryDeviceId === fallbackDeviceId) {
      throw new HttpsError("invalid-argument", "Primary and fallback printers must differ.");
    }
    const deviceIds = [primaryDeviceId, fallbackDeviceId].filter(Boolean);
    if (deviceIds.length > 0) {
      const devices = await db.getAll(...deviceIds.map((id) =>
        db.doc(`tenants/${tenantId}/devices/${id}`)));
      if (devices.some((device) => !device.exists ||
          device.data().venueId !== venueId ||
          device.data().active !== true ||
          !Array.isArray(device.data().productionAreas) ||
          !device.data().productionAreas.includes(productionArea))) {
        throw new HttpsError("failed-precondition", "A selected printer is not active for this venue and area.");
      }
    }
    const routeId = `${venueId}_${productionArea}`;
    await db.doc(`tenants/${tenantId}/printerRoutes/${routeId}`).set({
      venueId,
      productionArea,
      primaryDeviceId,
      fallbackDeviceId,
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    });
  } else {
    throw new HttpsError("invalid-argument", "That venue configuration resource is not supported.");
  }
  await writeAudit(caller.uid, "manageVenueConfiguration", resource, {
    tenantId, venueId, resource, actor,
  });
  return {saved: true};
}

async function uploadTenantLogoFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const fileName = requiredText(data, "fileName", 180)
    .replace(/[^a-zA-Z0-9._-]/g, "_");
  const contentType = requiredText(data, "contentType", 80).toLowerCase();
  if (!["image/png", "image/jpeg", "image/webp", "image/gif"].includes(contentType)) {
    throw new HttpsError("invalid-argument", "Upload a PNG, JPEG, WebP, or GIF image.");
  }
  const encoded = requiredText(data, "base64Data", 2800000);
  const bytes = Buffer.from(encoded, "base64");
  if (bytes.length === 0 || bytes.length >= 2 * 1024 * 1024 ||
      bytes.toString("base64").replace(/=+$/, "") !== encoded.replace(/=+$/, "")) {
    throw new HttpsError("invalid-argument", "The logo is invalid or exceeds 2 MB.");
  }
  const {roles} = await requireTenantOperationalMember(caller, tenantId);
  if (!roles.some((role) => role === "owner" || role === "manager")) {
    throw new HttpsError("permission-denied", "Only a manager can upload company branding.");
  }
  const venue = await db.doc(`tenants/${tenantId}/venues/${venueId}`).get();
  if (!venue.exists || venue.data().status === "deleting") {
    throw new HttpsError("failed-precondition", "The selected venue is not active.");
  }
  const downloadToken = randomUUID();
  const objectPath = `tenants/${tenantId}/branding/${Date.now()}-${fileName}`;
  const bucket = getStorage().bucket();
  await bucket.file(objectPath).save(bytes, {
    resumable: false,
    metadata: {
      contentType,
      metadata: {firebaseStorageDownloadTokens: downloadToken},
    },
  });
  const logoUrl = `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(objectPath)}?alt=media&token=${downloadToken}`;
  await writeAudit(caller.uid, "uploadTenantLogo", objectPath, {
    tenantId, venueId, contentType, size: bytes.length,
  });
  return {logoUrl};
}

function validRoles(value) {
  const supported = new Set([
    "owner", "manager", "waiter", "cashier", "kitchen", "printer",
  ]);
  if (!Array.isArray(value) || value.length === 0) {
    throw new HttpsError("invalid-argument", "At least one role is required.");
  }
  const roles = [...new Set(value)];
  if (roles.some((role) => typeof role !== "string" || !supported.has(role))) {
    throw new HttpsError("invalid-argument", "One or more roles are invalid.");
  }
  return roles;
}

function validCurrencyCode(data) {
  const currencyCode = (optionalText(data, "currencyCode", 3) || "GBP").toUpperCase();
  if (!supportedCurrencyCodeSet.has(currencyCode)) {
    throw new HttpsError(
      "invalid-argument",
      "currencyCode must be selected from the supported ISO currency list.",
    );
  }
  return currencyCode;
}

function requiredSixDigitPin(data) {
  const pin = requiredText(data, "pin", 6);
  if (!/^\d{6}$/.test(pin)) {
    throw new HttpsError("invalid-argument", "PIN must contain exactly six digits.");
  }
  return pin;
}

function staffPinDocumentId(venueId, userId) {
  return `${venueId}_${userId}`;
}

function hashStaffPin(pin, salt) {
  return scryptSync(pin, salt, 32).toString("base64");
}

async function listVenuePinStaffFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  await requireTenantOperationalMember(caller, tenantId);
  const venue = await db.doc(`tenants/${tenantId}/venues/${venueId}`).get();
  if (!venue.exists || venue.data().status === "deleting") {
    throw new HttpsError("failed-precondition", "The selected venue is not active.");
  }
  const members = await db.collection(`tenants/${tenantId}/members`)
    .where("active", "!=", false)
    .get();
  const staff = await Promise.all(members.docs.map(async (member) => {
    const userId = member.id;
    const [user, pin] = await Promise.all([
      auth.getUser(userId),
      db.doc(`tenants/${tenantId}/staffPins/${staffPinDocumentId(venueId, userId)}`).get(),
    ]);
    const pinData = pin.exists ? pin.data() : {};
    return {
      userId,
      displayName: user.displayName || user.email || "Staff member",
      roles: Array.isArray(member.data().roles) ? member.data().roles : [],
      hasPin: pin.exists,
      pinLocked: pinData.locked === true,
    };
  }));
  staff.sort((a, b) => a.displayName.localeCompare(b.displayName));
  return {staff};
}

async function setOwnStaffPinFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const pin = requiredSixDigitPin(data);
  await requireTenantOperationalMember(caller, tenantId);
  const venue = await db.doc(`tenants/${tenantId}/venues/${venueId}`).get();
  if (!venue.exists || venue.data().status === "deleting") {
    throw new HttpsError("failed-precondition", "The selected venue is not active.");
  }
  const salt = randomBytes(16).toString("base64url");
  const pinRef = db.doc(
    `tenants/${tenantId}/staffPins/${staffPinDocumentId(venueId, caller.uid)}`,
  );
  await pinRef.set({
    userId: caller.uid,
    venueId,
    salt,
    pinHash: hashStaffPin(pin, salt),
    failedAttempts: 0,
    locked: false,
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: caller.uid,
  });
  await writeAudit(caller.uid, "setOwnStaffPin", caller.uid, {tenantId, venueId});
  return {configured: true};
}

async function unlockStaffPinFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const userId = requiredText(data, "userId", 128);
  const {roles} = await requireTenantOperationalMember(caller, tenantId);
  if (!roles.some((role) => role === "owner" || role === "manager")) {
    throw new HttpsError("permission-denied", "Only a manager can unlock a staff PIN.");
  }
  const pinRef = db.doc(
    `tenants/${tenantId}/staffPins/${staffPinDocumentId(venueId, userId)}`,
  );
  const pin = await pinRef.get();
  if (!pin.exists || pin.data().venueId !== venueId) {
    throw new HttpsError("not-found", "This staff PIN was not found for the selected venue.");
  }
  await pinRef.update({
    locked: false,
    failedAttempts: 0,
    unlockedAt: FieldValue.serverTimestamp(),
    unlockedBy: caller.uid,
  });
  await writeAudit(caller.uid, "unlockStaffPin", userId, {tenantId, venueId});
  return {unlocked: true};
}

async function verifyStaffPinFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const userId = requiredText(data, "userId", 128);
  const pin = requiredSixDigitPin(data);
  await requireTenantOperationalMember(caller, tenantId);
  const memberRef = db.doc(`tenants/${tenantId}/members/${userId}`);
  const pinRef = db.doc(
    `tenants/${tenantId}/staffPins/${staffPinDocumentId(venueId, userId)}`,
  );
  const verification = await db.runTransaction(async (transaction) => {
    const [member, pinDocument] = await Promise.all([
      transaction.get(memberRef),
      transaction.get(pinRef),
    ]);
    if (!member.exists || member.data().active === false) {
      throw new HttpsError("permission-denied", "This staff account is not active.");
    }
    if (!pinDocument.exists) {
      throw new HttpsError("failed-precondition", "This staff member has not configured a PIN.");
    }
    const pinData = pinDocument.data();
    if (pinData.locked === true) {
      throw new HttpsError("resource-exhausted", "This staff PIN is locked. Ask a manager to unlock it.");
    }
    const expected = Buffer.from(pinData.pinHash, "base64");
    const supplied = Buffer.from(hashStaffPin(pin, pinData.salt), "base64");
    const valid = expected.length === supplied.length && timingSafeEqual(expected, supplied);
    if (!valid) {
      const failedAttempts = (Number.isInteger(pinData.failedAttempts)
        ? pinData.failedAttempts
        : 0) + 1;
      transaction.update(pinRef, {
        failedAttempts,
        locked: failedAttempts >= 3,
        lastFailedAt: FieldValue.serverTimestamp(),
      });
      return {valid: false, failedAttempts};
    }
    transaction.update(pinRef, {
      failedAttempts: 0,
      lastVerifiedAt: FieldValue.serverTimestamp(),
    });
    return {valid: true, failedAttempts: 0};
  });
  if (!verification.valid) {
    throw new HttpsError(
      verification.failedAttempts >= 3 ? "resource-exhausted" : "permission-denied",
      verification.failedAttempts >= 3
        ? "This staff PIN is now locked after three failed attempts."
        : `Incorrect PIN. ${3 - verification.failedAttempts} attempt(s) remain.`,
    );
  }
  const token = randomBytes(32).toString("base64url");
  const expiresAt = new Date(Date.now() + 30 * 60 * 1000);
  const sessionRef = db.collection(`tenants/${tenantId}/staffPinSessions`).doc();
  await sessionRef.set({
    userId,
    venueId,
    hostUserId: caller.uid,
    tokenHash: createHash("sha256").update(token).digest("base64"),
    expiresAt,
    createdAt: FieldValue.serverTimestamp(),
  });
  const [user, platformAdmin, verifiedMembership] = await Promise.all([
    auth.getUser(userId),
    db.doc(`platformAdmins/${userId}`).get(),
    memberRef.get(),
  ]);
  await writeAudit(caller.uid, "verifyStaffPin", userId, {tenantId, venueId});
  return {
    sessionId: sessionRef.id,
    sessionToken: token,
    expiresAt: expiresAt.toISOString(),
    userId,
    displayName: user.displayName || user.email || "Staff member",
    isPlatformAdmin: platformAdmin.exists || user.customClaims?.platformAdmin === true,
    roles: Array.isArray(verifiedMembership.data()?.roles)
      ? verifiedMembership.data().roles
      : [],
  };
}

async function actingCallerFromStaffSession(hostCaller, data) {
  const sessionId = optionalText(data, "staffPinSessionId", 128);
  const sessionToken = optionalText(data, "staffPinSessionToken", 128);
  if (!sessionId && !sessionToken) {
    throw new HttpsError(
      "unauthenticated",
      "Select your staff name and enter your PIN before using the POS.",
    );
  }
  if (!sessionId || !sessionToken) {
    throw new HttpsError("unauthenticated", "The shared-device staff session is incomplete.");
  }
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const session = await db.doc(
    `tenants/${tenantId}/staffPinSessions/${sessionId}`,
  ).get();
  if (!session.exists) {
    throw new HttpsError("unauthenticated", "The staff PIN session no longer exists.");
  }
  const sessionData = session.data();
  const suppliedHash = createHash("sha256").update(sessionToken).digest("base64");
  const expectedHash = typeof sessionData.tokenHash === "string"
    ? sessionData.tokenHash
    : "";
  const hashesMatch = expectedHash.length === suppliedHash.length &&
    timingSafeEqual(Buffer.from(expectedHash), Buffer.from(suppliedHash));
  const expiresAt = sessionData.expiresAt?.toDate?.() ?? null;
  if (!hashesMatch ||
      sessionData.hostUserId !== hostCaller.uid ||
      sessionData.venueId !== venueId ||
      expiresAt == null ||
      expiresAt.getTime() <= Date.now()) {
    throw new HttpsError("unauthenticated", "The staff PIN session has expired. Select your name and enter your PIN again.");
  }
  const actingUserId = typeof sessionData.userId === "string"
    ? sessionData.userId
    : "";
  const membership = await db.doc(`tenants/${tenantId}/members/${actingUserId}`).get();
  if (!membership.exists || membership.data().active === false) {
    throw new HttpsError("permission-denied", "The selected staff account is no longer active.");
  }
  return {...hostCaller, uid: actingUserId, hostUid: hostCaller.uid};
}

function xmlElementText(xml, tagName) {
  const match = new RegExp(
    `<${tagName}\\b[^>]*>\\s*([^<]*?)\\s*</${tagName}>`,
    "i",
  ).exec(xml);
  return match == null ? "" : match[1].trim();
}

function decimalTextToScaled(value, label) {
  const text = String(value).trim();
  if (!/^\d+(?:\.\d+)?$/.test(text)) {
    throw new HttpsError("unavailable", `${label} was not present in the official rate feed.`);
  }
  const [whole, rawFraction = ""] = text.split(".");
  let scaled = (BigInt(whole) * 1000000n) +
    BigInt(rawFraction.slice(0, 6).padEnd(6, "0"));
  // The POS rate has six decimal places. Round the published value once if
  // CBRT adds additional precision in a future bulletin.
  if (rawFraction.length > 6 && Number(rawFraction.charAt(6)) >= 5) scaled += 1n;
  if (scaled <= 0n) {
    throw new HttpsError("unavailable", `${label} was not a positive official rate.`);
  }
  return scaled;
}

function formatScaledExchangeRate(scaled) {
  const whole = scaled / 1000000n;
  const fraction = (scaled % 1000000n).toString().padStart(6, "0").replace(/0+$/, "");
  return fraction.length === 0 ? whole.toString() : `${whole}.${fraction}`;
}

function parseCbrtDailyRates(xml) {
  const publicationDate = /<Tarih_Date\b[^>]*\bDate\s*=\s*["']([^"']+)["']/i
    .exec(xml)?.[1]
    ?.trim();
  if (publicationDate == null || publicationDate.length === 0) {
    throw new HttpsError("unavailable", "The official rate feed did not include its publication date.");
  }

  const tryPerCurrency = new Map([["TRY", 1000000n]]);
  const currencyMatcher = /<Currency\b([^>]*)>([\s\S]*?)<\/Currency>/gi;
  for (const match of xml.matchAll(currencyMatcher)) {
    const currencyCode = /\bCurrencyCode\s*=\s*["']([^"']+)["']/i
      .exec(match[1])?.[1]
      ?.trim()
      .toUpperCase();
    if (currencyCode == null || !/^[A-Z]{3}$/.test(currencyCode)) continue;
    const unitText = xmlElementText(match[2], "Unit");
    const forexBuyingText = xmlElementText(match[2], "ForexBuying");
    if (!/^\d+$/.test(unitText) || forexBuyingText.length === 0) continue;
    const unit = BigInt(unitText);
    if (unit <= 0n) continue;
    const quotedTryScaled = decimalTextToScaled(
      forexBuyingText,
      `The official ${currencyCode} ForexBuying value`,
    );
    // The CBRT bulletin may quote (for example) 100 JPY. Store every entry
    // as Turkish lira for one major unit of its currency.
    tryPerCurrency.set(
      currencyCode,
      (quotedTryScaled + (unit / 2n)) / unit,
    );
  }
  return {publicationDate, tryPerCurrency};
}

async function currentCbrtDailyRates() {
  const now = Date.now();
  if (cbrtRateCache != null && cbrtRateCache.expiresAt > now) {
    return cbrtRateCache.feed;
  }
  let response;
  try {
    response = await fetch(cbrtDailyRatesUrl, {
      headers: {accept: "application/xml,text/xml;q=0.9,*/*;q=0.1"},
      signal: AbortSignal.timeout(10000),
    });
  } catch (error) {
    console.warn("Could not download the CBRT daily rate feed.", error);
    throw new HttpsError(
      "unavailable",
      "The official exchange-rate service is unavailable. Enter a manager rate manually.",
    );
  }
  if (!response.ok) {
    console.warn(`CBRT daily rate feed returned HTTP ${response.status}.`);
    throw new HttpsError(
      "unavailable",
      "The official exchange-rate service is unavailable. Enter a manager rate manually.",
    );
  }
  const xml = await response.text();
  if (xml.length === 0 || xml.length > 1024 * 1024) {
    throw new HttpsError(
      "unavailable",
      "The official exchange-rate response was invalid. Enter a manager rate manually.",
    );
  }
  const feed = parseCbrtDailyRates(xml);
  cbrtRateCache = {feed, expiresAt: now + cbrtRateCacheTtlMs};
  return feed;
}

async function lookupExchangeRateFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const tenderCurrencyCode = requiredText(data, "tenderCurrencyCode", 3).toUpperCase();
  if (!supportedCurrencyCodeSet.has(tenderCurrencyCode)) {
    throw new HttpsError("invalid-argument", "tenderCurrencyCode must be a supported ISO currency code.");
  }
  await requireTenantOperationalMember(caller, tenantId);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const [tenant, venue] = await Promise.all([tenantRef.get(), venueRef.get()]);
  if (!tenant.exists) throw new HttpsError("not-found", "The restaurant was not found.");
  if (!venue.exists || venue.data().status === "deleting") {
    throw new HttpsError("failed-precondition", "The selected venue is not active.");
  }
  const baseCurrencyCode = String(tenant.data().currencyCode ?? "GBP").toUpperCase();
  if (!supportedCurrencyCodeSet.has(baseCurrencyCode)) {
    throw new HttpsError("failed-precondition", "The restaurant has an invalid reporting currency.");
  }
  const fetchedAt = new Date().toISOString();
  if (tenderCurrencyCode === baseCurrencyCode) {
    return {
      tenderCurrencyCode,
      baseCurrencyCode,
      exchangeRateToBase: "1",
      source: "No conversion required",
      publishedDate: null,
      fetchedAt,
    };
  }

  const feed = await currentCbrtDailyRates();
  const tenderTryScaled = feed.tryPerCurrency.get(tenderCurrencyCode);
  const baseTryScaled = feed.tryPerCurrency.get(baseCurrencyCode);
  if (tenderTryScaled == null || baseTryScaled == null) {
    throw new HttpsError(
      "unavailable",
      `The official CBRT daily bulletin does not provide a ${tenderCurrencyCode}/${baseCurrencyCode} rate. Enter a manager rate manually.`,
    );
  }
  // one tender-currency major unit = X base-currency major units
  const exchangeRateScaled = ((tenderTryScaled * 1000000n) +
    (baseTryScaled / 2n)) / baseTryScaled;
  if (exchangeRateScaled <= 0n) {
    throw new HttpsError("unavailable", "The official rate calculation was invalid. Enter a manager rate manually.");
  }
  console.info(
    `Official CBRT rate loaded for ${tenantId}/${venueId}: ${tenderCurrencyCode}/${baseCurrencyCode}.`,
  );
  return {
    tenderCurrencyCode,
    baseCurrencyCode,
    exchangeRateToBase: formatScaledExchangeRate(exchangeRateScaled),
    source: "CBRT daily indicative rate (Forex buying)",
    publishedDate: feed.publicationDate,
    fetchedAt,
  };
}

function validTimeZone(data) {
  const timeZone = optionalText(data, "timeZone", 80) || "Europe/London";
  if (!supportedTimeZoneSet.has(timeZone)) {
    throw new HttpsError(
      "invalid-argument",
      "timeZone must be selected from the supported IANA time-zone list.",
    );
  }
  return timeZone;
}

function venueNameKey(name) {
  return name
    .normalize("NFKC")
    .replace(/\s+/g, " ")
    .trim()
    .toLocaleLowerCase("en-GB");
}

function throwIfVenueNameExists(venues, nameKey, ignoredVenueId = null) {
  const duplicate = venues.docs.find((document) => {
    const storedName = document.data().name;
    return document.id !== ignoredVenueId
      && typeof storedName === "string"
      && venueNameKey(storedName) === nameKey;
  });
  if (duplicate != null) {
    throw new HttpsError(
      "already-exists",
      "A venue with that name already exists in this restaurant.",
    );
  }
}

function actorSnapshot(user) {
  // Retain a minimal immutable attribution record on business data. The Auth
  // user may later be retired, but this UID/name pair remains meaningful.
  return {
    uid: user.uid,
    displayName: user.displayName ?? "",
  };
}

async function createOrUpdateStaffProfile(user, actorUid, status = "active") {
  const profileRef = db.doc(`staffProfiles/${user.uid}`);
  const existing = await profileRef.get();
  const updates = {
    uid: user.uid,
    displayName: user.displayName ?? "",
    email: user.email ?? "",
    status,
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: actorUid,
  };
  if (!existing.exists) {
    updates.createdAt = FieldValue.serverTimestamp();
    updates.createdBy = actorUid;
  }
  await profileRef.set(updates, {merge: true});
}

async function revokeMembershipsFor(userUid, actorUid) {
  const memberships = await db.collectionGroup("members")
    .where("userId", "==", userUid)
    .get();

  // A Firestore batch may contain at most 500 writes. Chunks keep retirement
  // safe even if a staff member is assigned to many restaurant companies.
  const documents = memberships.docs;
  for (let start = 0; start < documents.length; start += 450) {
    const batch = db.batch();
    for (const document of documents.slice(start, start + 450)) {
      batch.set(document.ref, {
        active: false,
        retiredAt: FieldValue.serverTimestamp(),
        retiredBy: actorUid,
      }, {merge: true});
    }
    await batch.commit();
  }
  return documents.length;
}

async function writeAudit(callerUid, action, target, details = {}) {
  await db.collection("platformAdminAudit").add({
    callerUid,
    action,
    target,
    details,
    createdAt: FieldValue.serverTimestamp(),
  });
}

async function bootstrapPlatformAdminFor(caller) {
  const configuredEmail = initialPlatformAdminEmail.value().trim().toLowerCase();
  const callerEmail = typeof caller.token.email === "string"
    ? caller.token.email.toLowerCase()
    : "";

  if (configuredEmail.length === 0 || callerEmail !== configuredEmail) {
    throw new HttpsError("permission-denied", "This account cannot bootstrap the platform.");
  }

  const existingAdmins = await db.collection("platformAdmins").limit(1).get();
  if (!existingAdmins.empty && !existingAdmins.docs.some((item) => item.id === caller.uid)) {
    throw new HttpsError("failed-precondition", "A platform administrator already exists.");
  }

  const user = await auth.getUser(caller.uid);
  await auth.setCustomUserClaims(caller.uid, {
    ...(user.customClaims ?? {}),
    platformAdmin: true,
  });
  await db.doc(`platformAdmins/${caller.uid}`).set({
    email: user.email ?? callerEmail,
    createdAt: FieldValue.serverTimestamp(),
  }, {merge: true});
  await createOrUpdateStaffProfile(user, caller.uid);
  await writeAudit(caller.uid, "bootstrapPlatformAdmin", caller.uid);
  return {claimUpdated: true};
}

async function listAuthUsersFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const pageToken = optionalText(data, "pageToken", 2000) || undefined;
  const page = await auth.listUsers(100, pageToken);
  return {
    users: page.users.map((user) => ({
      uid: user.uid,
      email: user.email ?? "",
      displayName: user.displayName ?? "",
      disabled: user.disabled,
      platformAdmin: user.customClaims?.platformAdmin === true,
    })),
    nextPageToken: page.pageToken ?? null,
  };
}

async function listTenantsFor(caller) {
  await requirePlatformAdmin(caller);
  const snapshot = await db.collection("tenants").orderBy("displayName").limit(200).get();
  return {
    tenants: snapshot.docs.map((document) => ({
      id: document.id,
      displayName: document.data().displayName ?? "Unnamed restaurant",
      legalName: document.data().legalName ?? "",
      currencyCode: document.data().currencyCode ?? "GBP",
    })),
  };
}

async function listSupportedTimeZonesFor(caller) {
  await requirePlatformAdmin(caller);
  return {timeZones: supportedTimeZones};
}

async function listSupportedCurrenciesFor(caller) {
  await requirePlatformAdmin(caller);
  return {currencyCodes: supportedCurrencyCodes};
}

async function listTenantVenuesFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const tenant = await tenantRef.get();
  if (!tenant.exists) {
    throw new HttpsError("not-found", "The restaurant was not found.");
  }
  const snapshot = await tenantRef.collection("venues").orderBy("name").limit(200).get();
  return {
    venues: snapshot.docs.map((document) => ({
      id: document.id,
      name: document.data().name ?? "Unnamed venue",
      timeZone: document.data().timeZone ?? "Europe/London",
    })),
  };
}

async function listUserMembershipsFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const userUid = requiredText(data, "userUid", 128);
  const snapshot = await db.collectionGroup("members")
    .where("userId", "==", userUid)
    .get();
  return {
    memberships: snapshot.docs
      .filter((document) => document.data().active !== false)
      .map((document) => ({
        tenantId: document.ref.parent.parent.id,
        roles: Array.isArray(document.data().roles) ? document.data().roles : [],
        defaultVenueId: document.data().defaultVenueId ?? null,
      })),
  };
}

async function createTenantFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const displayName = requiredText(data, "displayName");
  const legalName = optionalText(data, "legalName");
  const currencyCode = validCurrencyCode(data);
  const venueName = requiredText(data, "venueName");
  const timeZone = validTimeZone(data);
  const ownerUid = requiredText(data, "ownerUid", 128);
  const [owner, creator] = await Promise.all([
    auth.getUser(ownerUid),
    auth.getUser(caller.uid),
  ]);
  if (owner.disabled) {
    throw new HttpsError("failed-precondition", "A retired user cannot own a restaurant.");
  }
  const creatorSnapshot = actorSnapshot(creator);
  const tenantRef = db.collection("tenants").doc();
  const venueRef = tenantRef.collection("venues").doc();
  const memberRef = tenantRef.collection("members").doc(ownerUid);

  await db.runTransaction(async (transaction) => {
    transaction.create(tenantRef, {
      displayName,
      legalName,
      currencyCode,
      createdAt: FieldValue.serverTimestamp(),
      createdBy: caller.uid,
      createdByActor: creatorSnapshot,
    });
    transaction.create(venueRef, {
      name: venueName,
      nameKey: venueNameKey(venueName),
      timeZone,
      notificationRetentionSeconds: 5,
      orderFlowAmberMinutes: 15,
      orderFlowRedMinutes: 25,
      businessDayCutoffMinutes: 240,
      status: "active",
      createdAt: FieldValue.serverTimestamp(),
    });
    transaction.create(memberRef, {
      userId: owner.uid,
      roles: ["owner"],
      defaultVenueId: venueRef.id,
      email: owner.email ?? "",
      active: true,
      createdAt: FieldValue.serverTimestamp(),
      createdBy: caller.uid,
      createdByActor: creatorSnapshot,
    });
  });

  await createOrUpdateStaffProfile(owner, caller.uid);

  await writeAudit(caller.uid, "createTenant", tenantRef.id, {ownerUid, venueId: venueRef.id});
  return {tenantId: tenantRef.id, venueId: venueRef.id};
}

async function updateTenantFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const displayName = requiredText(data, "displayName");
  const legalName = optionalText(data, "legalName");
  const currencyCode = validCurrencyCode(data);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const tenant = await tenantRef.get();
  if (!tenant.exists) {
    throw new HttpsError("not-found", "The restaurant was not found.");
  }
  const currentCurrencyCode = String(tenant.data().currencyCode ?? "GBP").toUpperCase();
  if (currencyCode !== currentCurrencyCode) {
    // Currency is picked while creating a restaurant and then immutable. A
    // price is stored as a bare integer in the currency's minor units, so an
    // apparently harmless later change can reinterpret money created during
    // a concurrent menu edit. A new restaurant is the safe migration path.
    throw new HttpsError(
      "failed-precondition",
      "The functional currency is permanent once a restaurant is created. Create a new restaurant company for a different trading currency; existing amounts are never converted automatically.",
    );
  }
  await tenantRef.set({
    displayName,
    legalName,
    currencyCode,
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: caller.uid,
  }, {merge: true});
  await writeAudit(caller.uid, "updateTenant", tenantId);
  return {updated: true};
}

async function createVenueFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const name = requiredText(data, "name");
  const nameKey = venueNameKey(name);
  const timeZone = validTimeZone(data);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc();
  await db.runTransaction(async (transaction) => {
    const [tenant, venues] = await Promise.all([
      transaction.get(tenantRef),
      transaction.get(tenantRef.collection("venues")),
    ]);
    if (!tenant.exists) {
      throw new HttpsError("not-found", "The restaurant was not found.");
    }
    throwIfVenueNameExists(venues, nameKey);
    transaction.create(venueRef, {
      name,
      nameKey,
      timeZone,
      notificationRetentionSeconds: 5,
      orderFlowAmberMinutes: 15,
      orderFlowRedMinutes: 25,
      businessDayCutoffMinutes: 240,
      status: "active",
      createdAt: FieldValue.serverTimestamp(),
      createdBy: caller.uid,
    });
  });
  await writeAudit(caller.uid, "createVenue", venueRef.id, {tenantId});
  return {id: venueRef.id, name, timeZone};
}

async function updateVenueFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const name = requiredText(data, "name");
  const nameKey = venueNameKey(name);
  const timeZone = validTimeZone(data);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = db.doc(`tenants/${tenantId}/venues/${venueId}`);
  await db.runTransaction(async (transaction) => {
    const [venue, venues] = await Promise.all([
      transaction.get(venueRef),
      transaction.get(tenantRef.collection("venues")),
    ]);
    if (!venue.exists) {
      throw new HttpsError("not-found", "The venue was not found.");
    }
    if (venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "This venue is currently being deleted.");
    }
    throwIfVenueNameExists(venues, nameKey, venueId);
    transaction.set(venueRef, {
      name,
      nameKey,
      timeZone,
      updatedAt: FieldValue.serverTimestamp(),
      updatedBy: caller.uid,
    }, {merge: true});
  });
  await writeAudit(caller.uid, "updateVenue", venueId, {tenantId});
  return {id: venueId, name, timeZone};
}

// Any future tenant-root collection that stores a venueId must be added here
// before it is deployed, so deleting a venue never leaves orphaned records.
const venueDependencyCollections = Object.freeze([
  "tables",
  "orders",
  "productionTickets",
  "stockMovements",
  "bills",
  "paymentRequests",
  "devices",
  "printJobs",
]);

async function clearDefaultVenuePointers(memberships) {
  const documents = memberships.docs;
  for (let start = 0; start < documents.length; start += 450) {
    const batch = db.batch();
    for (const document of documents.slice(start, start + 450)) {
      batch.set(document.ref, {defaultVenueId: FieldValue.delete()}, {merge: true});
    }
    await batch.commit();
  }
  return documents.length;
}

async function deleteVenueFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  // The transaction makes the deletion lock exclusive. The status then makes
  // security rules reject new venue-bound client writes while the dependency
  // check runs, closing the gap between checking and deleting.
  await db.runTransaction(async (transaction) => {
    const venue = await transaction.get(venueRef);
    if (!venue.exists) {
      throw new HttpsError("not-found", "The venue was not found.");
    }
    if (venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "This venue is already being deleted.");
    }
    transaction.set(venueRef, {
      status: "deleting",
      deletionRequestedAt: FieldValue.serverTimestamp(),
      deletionRequestedBy: caller.uid,
    }, {merge: true});
  });

  let deleted = false;
  try {
    const venues = await tenantRef.collection("venues").limit(2).get();
    if (venues.size < 2) {
      throw new HttpsError(
        "failed-precondition",
        "A restaurant must retain at least one venue. Add another venue before deleting this one.",
      );
    }
    const [memberships, ...dependencies] = await Promise.all([
      tenantRef.collection("members")
        .where("defaultVenueId", "==", venueId)
        .get(),
      ...venueDependencyCollections.map(async (collectionName) => ({
        collectionName,
        snapshot: await tenantRef.collection(collectionName)
          .where("venueId", "==", venueId)
          .limit(1)
          .get(),
      })),
    ]);
    const blockers = dependencies
      .filter((dependency) => !dependency.snapshot.empty)
      .map((dependency) => dependency.collectionName);
    if (blockers.length > 0) {
      throw new HttpsError(
        "failed-precondition",
        `The venue cannot be deleted because it still has ${blockers.join(", ")} data.`,
      );
    }

    const clearedDefaultVenuePointers = await clearDefaultVenuePointers(memberships);
    await venueRef.delete();
    deleted = true;
    try {
      await writeAudit(caller.uid, "deleteVenue", venueId, {
        tenantId,
        clearedDefaultVenuePointers,
      });
    } catch (auditError) {
      // The delete has already completed safely. Log a failed audit write
      // without incorrectly telling the caller that the venue still exists.
      console.error("Could not write deleteVenue audit record", auditError);
    }
    return {deleted: true, clearedDefaultVenuePointers};
  } catch (error) {
    if (!deleted) {
      await venueRef.set({
        status: "active",
        deletionRequestedAt: FieldValue.delete(),
        deletionRequestedBy: FieldValue.delete(),
      }, {merge: true});
    }
    throw error;
  }
}

async function createStaffUserFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const email = requiredText(data, "email", 320).toLowerCase();
  const displayName = optionalText(data, "displayName");
  // The person must use the app's reset-password action before their first sign-in.
  const user = await auth.createUser({
    email,
    displayName: displayName || undefined,
    password: randomBytes(32).toString("base64url"),
  });
  await createOrUpdateStaffProfile(user, caller.uid);
  await writeAudit(caller.uid, "createStaffUser", user.uid, {email});
  return {uid: user.uid, email: user.email ?? email};
}

async function assignUserToTenantFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const userUid = requiredText(data, "userUid", 128);
  const roles = validRoles(data.roles);
  const defaultVenueId = optionalText(data, "defaultVenueId", 128) || null;
  const [tenant, user] = await Promise.all([
    db.doc(`tenants/${tenantId}`).get(),
    auth.getUser(userUid),
  ]);
  if (!tenant.exists) {
    throw new HttpsError("not-found", "The restaurant was not found.");
  }
  if (user.disabled) {
    throw new HttpsError("failed-precondition", "A retired user cannot be assigned access.");
  }

  await db.doc(`tenants/${tenantId}/members/${user.uid}`).set({
    userId: user.uid,
    roles,
    defaultVenueId,
    email: user.email ?? "",
    active: true,
    retiredAt: FieldValue.delete(),
    retiredBy: FieldValue.delete(),
    updatedAt: FieldValue.serverTimestamp(),
    updatedBy: caller.uid,
  }, {merge: true});
  await createOrUpdateStaffProfile(user, caller.uid);
  await writeAudit(caller.uid, "assignUserToTenant", user.uid, {tenantId, roles});
  return {assigned: true};
}

async function retireStaffUserFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const userUid = requiredText(data, "userUid", 128);
  const [user, platformAdmin] = await Promise.all([
    auth.getUser(userUid),
    db.doc(`platformAdmins/${userUid}`).get(),
  ]);

  // The master account remains the recovery route for the whole SaaS. Never
  // permit retirement through either the durable record or custom claim.
  if (platformAdmin.exists || user.customClaims?.platformAdmin === true) {
    throw new HttpsError(
      "failed-precondition",
      "A platform administrator cannot be deleted or retired.",
    );
  }

  const membershipsRevoked = await revokeMembershipsFor(userUid, caller.uid);
  await auth.updateUser(userUid, {disabled: true});
  await auth.revokeRefreshTokens(userUid);
  await createOrUpdateStaffProfile(user, caller.uid, "retired");
  await db.doc(`staffProfiles/${userUid}`).set({
    retiredAt: FieldValue.serverTimestamp(),
    retiredBy: caller.uid,
  }, {merge: true});
  await writeAudit(caller.uid, "retireStaffUser", userUid, {membershipsRevoked});
  return {retired: true, membershipsRevoked};
}

async function setPlatformAdminFor(caller, rawData) {
  await requirePlatformAdmin(caller);
  const data = requireObject(rawData);
  const userUid = requiredText(data, "userUid", 128);
  const enabled = data.enabled === true;
  const user = await auth.getUser(userUid);

  if (!enabled && caller.uid === userUid) {
    const admins = await db.collection("platformAdmins").limit(2).get();
    if (admins.size < 2) {
      throw new HttpsError("failed-precondition", "Keep at least one platform administrator.");
    }
  }

  await auth.setCustomUserClaims(userUid, {
    ...(user.customClaims ?? {}),
    platformAdmin: enabled,
  });
  const ref = db.doc(`platformAdmins/${userUid}`);
  if (enabled) {
    await ref.set({
      email: user.email ?? "",
      grantedBy: caller.uid,
      createdAt: FieldValue.serverTimestamp(),
    }, {merge: true});
    await createOrUpdateStaffProfile(user, caller.uid);
  } else {
    await ref.delete();
  }
  await writeAudit(caller.uid, "setPlatformAdmin", userUid, {enabled});
  return {updated: true};
}

async function requireTenantManager(caller, tenantId) {
  const {roles} = await requireTenantOperationalMember(caller, tenantId);
  if (!roles.some((role) => role === "owner" || role === "manager")) {
    throw new HttpsError("permission-denied", "Only an owner or manager can change tables.");
  }
  return roles;
}

async function requireTenantOwner(caller, tenantId) {
  const {roles} = await requireTenantOperationalMember(caller, tenantId);
  if (!roles.includes("owner")) {
    throw new HttpsError(
      "permission-denied",
      "Only a company owner can change this venue setting.",
    );
  }
  return roles;
}

function tableLabelKey(label) {
  return venueNameKey(label);
}

function tableLabelRegistryRef(tenantId, venueId, labelKey) {
  const encoded = Buffer.from(`${venueId}\u0000${labelKey}`).toString("base64url");
  return db.doc(`tenants/${tenantId}/tableLabels/${encoded}`);
}

function openTabRegistryRef(tenantId, venueId, tabName) {
  const key = venueNameKey(tabName);
  const encoded = Buffer.from(`${venueId}\u0000${key}`).toString("base64url");
  return db.doc(`tenants/${tenantId}/openTabNames/${encoded}`);
}

async function openNamedTabFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const tabName = requiredText(data, "tabName", 80);
  await requireTenantOperationalMember(caller, tenantId);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const tabRef = openTabRegistryRef(tenantId, venueId, tabName);
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  const result = await db.runTransaction(async (transaction) => {
    const [venue, currentTab] = await Promise.all([
      transaction.get(venueRef),
      transaction.get(tabRef),
    ]);
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (currentTab.exists) {
      const currentOrderId = currentTab.data().orderId;
      const currentOrder = typeof currentOrderId === "string"
        ? await transaction.get(tenantRef.collection("orders").doc(currentOrderId))
        : null;
      if (currentOrder?.exists
          && currentOrder.data().venueId === venueId
          && currentOrder.data().status !== "closed") {
        return {orderId: currentOrderId, reopened: true};
      }
      // A later bill-close command normally removes this reservation. Clean up
      // a stale one defensively so a missing/closed historic order cannot
      // permanently block a customer name.
      transaction.delete(tabRef);
    }
    const orderRef = tenantRef.collection("orders").doc();
    transaction.create(orderRef, {
      venueId,
      tabName,
      tabNameKey: venueNameKey(tabName),
      status: "open",
      openedAt: FieldValue.serverTimestamp(),
      createdByActor: actor,
      lines: [],
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    });
    transaction.create(tabRef, {
      venueId,
      tabName,
      tabNameKey: venueNameKey(tabName),
      orderId: orderRef.id,
      createdAt: FieldValue.serverTimestamp(),
    });
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "openNamedTab",
      venueId,
      tabName,
      orderId: orderRef.id,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {orderId: orderRef.id, reopened: false};
  });
  return result;
}

// Draft lines are deliberately written by this trusted API rather than by the
// client directly.  They are visible to every till straight away, but remain
// harmless until sendOrderToProductionFor creates the ticket and stock move.
async function addOrderDraftLineFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const orderId = requiredText(data, "orderId", 180);
  const tableId = optionalText(data, "tableId", 180) || null;
  const tabName = optionalText(data, "tabName", 80) || null;
  if ((tableId == null) === (tabName == null)) {
    throw new HttpsError(
      "invalid-argument",
      "Choose either a table or a named tab for the order.",
    );
  }
  const line = validProductionLine(data.line, 0);
  await requireTenantOperationalMember(caller, tenantId);

  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const tableRef = tableId == null ? null : tenantRef.collection("tables").doc(tableId);
  const tabRef = tabName == null ? null : openTabRegistryRef(tenantId, venueId, tabName);
  const orderRef = tenantRef.collection("orders").doc(orderId);
  const productRef = tenantRef.collection("products").doc(line.productId);
  const actor = actorSnapshot(await auth.getUser(caller.uid));

  return db.runTransaction(async (transaction) => {
    const [venue, table, namedTab, existingOrder, product] = await Promise.all([
      transaction.get(venueRef),
      tableRef == null ? Promise.resolve(null) : transaction.get(tableRef),
      tabRef == null ? Promise.resolve(null) : transaction.get(tabRef),
      transaction.get(orderRef),
      transaction.get(productRef),
    ]);
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (tableRef != null && (!table.exists || table.data().venueId !== venueId)) {
      throw new HttpsError("failed-precondition", "The selected table is not available at this venue.");
    }
    if (tableRef != null) {
      const currentOrderId = table.data().currentOrderId;
      if (typeof currentOrderId === "string" && currentOrderId !== orderId) {
        throw new HttpsError(
          "failed-precondition",
          "This table already has a different open order. Reopen that bill instead.",
        );
      }
    }
    if (tabRef != null && (!namedTab.exists || namedTab.data().orderId !== orderId)) {
      throw new HttpsError(
        "failed-precondition",
        "A different open tab already uses this name. Reopen it instead.",
      );
    }
    if (existingOrder.exists) {
      const current = existingOrder.data();
      if (current.venueId !== venueId || current.status === "closed") {
        throw new HttpsError("failed-precondition", "This order is no longer open at this venue.");
      }
      if ((current.tableId ?? null) !== tableId || (current.tabName ?? null) !== tabName) {
        throw new HttpsError("failed-precondition", "This order belongs to a different table or named tab.");
      }
      const priorLines = Array.isArray(current.lines) ? current.lines : [];
      // A lost HTTP response must never result in the same tap being added
      // twice. Line IDs are generated once by the client and are idempotent.
      if (priorLines.some((item) => item?.id === line.id)) {
        return {orderId, saved: true, alreadyPresent: true};
      }
    }
    if (!product.exists || product.data().venueId !== venueId) {
      throw new HttpsError("not-found", "A selected menu product no longer exists at this venue.");
    }
    const productData = product.data();
    const modifierGroupIds = configuredModifierGroupIds(productData);
    const modifierGroups = await Promise.all(
      modifierGroupIds.map((groupId) =>
        transaction.get(tenantRef.collection("modifierGroups").doc(groupId))),
    );
    const modifierGroupsById = new Map(
      modifierGroups.map((group) => [group.id, group.exists ? group.data() : null]),
    );
    const configuration = canonicalLineConfiguration({
      productData,
      modifierGroupsById,
      line,
    });
    if (productData.isAvailable === false) {
      throw new HttpsError("failed-precondition", "This product is currently unavailable.");
    }
    const basePriceMinor = Number(productData.priceMinor);
    const unitPriceMinor = basePriceMinor + configuration.priceDeltaMinor;
    const stockPerSale = Number(productData.stockPerSale ?? 1);
    if (!Number.isSafeInteger(unitPriceMinor) || unitPriceMinor < 0
        || !Number.isFinite(stockPerSale) || stockPerSale <= 0) {
      throw new HttpsError("failed-precondition", "This product has invalid saved sale details.");
    }
    if (productData.trackStock === true) {
      const onHand = Number(productData.stockOnHand ?? 0);
      if (!Number.isFinite(onHand) || onHand < line.quantity * stockPerSale) {
        throw new HttpsError(
          "failed-precondition",
          "This tracked product is sold out. A manager can only override stock when sending the order.",
        );
      }
    }
    const productionArea = productData.productionArea === "bar"
      ? "bar"
      : productData.productionArea === "dessert"
        ? "dessert"
        : "kitchen";
    const taxRateBasisPoints = validTaxRateBasisPoints(
      productData.taxRateBasisPoints,
    );
    const canonicalLine = {
      id: line.id,
      productId: line.productId,
      productName: typeof productData.name === "string" ? productData.name : "Menu item",
      quantity: line.quantity,
      unitPriceMinor,
      productionArea,
      trackStock: productData.trackStock === true,
      stockPerSale,
      taxRateBasisPoints,
      taxRateId: typeof productData.taxRateId === "string" ? productData.taxRateId : null,
      taxRateName: typeof productData.taxRateName === "string"
        ? productData.taxRateName
        : "Zero rate",
      variantId: configuration.variantId,
      variantName: configuration.variantName,
      variantPriceDeltaMinor: configuration.variantPriceDeltaMinor,
      modifierSelections: configuration.modifierSelections,
      itemNote: configuration.itemNote,
      isSentToProduction: false,
    };
    const current = existingOrder.exists ? existingOrder.data() : null;
    const priorLines = Array.isArray(current?.lines) ? current.lines : [];
    const tableLabel = tableRef == null
      ? null
      : (typeof table.data().label === "string" ? table.data().label : tableId);
    transaction.set(orderRef, {
      venueId,
      tableId,
      tabName,
      tableLabel,
      status: current?.status === "sent" ? "sent" : "open",
      openedAt: current?.openedAt ?? FieldValue.serverTimestamp(),
      createdByActor: current?.createdByActor ?? actor,
      lines: [...priorLines, canonicalLine],
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    }, {merge: true});
    if (tableRef != null) {
      transaction.update(tableRef, {
        currentOrderId: orderId,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "addOrderDraftLine",
      venueId,
      orderId,
      tableId,
      tabName,
      lineId: line.id,
      productId: line.productId,
      quantity: line.quantity,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {orderId, saved: true, alreadyPresent: false};
  });
}

async function updateOrderDraftLineFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const orderId = requiredText(data, "orderId", 180);
  const tableId = optionalText(data, "tableId", 180) || null;
  const tabName = optionalText(data, "tabName", 80) || null;
  if ((tableId == null) === (tabName == null)) {
    throw new HttpsError(
      "invalid-argument",
      "Choose either a table or a named tab for the order.",
    );
  }
  const lineId = requiredText(data, "lineId", 180);
  const quantity = requiredNonNegativeInteger(data.quantity, "quantity", 100);
  await requireTenantOperationalMember(caller, tenantId);

  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const tableRef = tableId == null ? null : tenantRef.collection("tables").doc(tableId);
  const tabRef = tabName == null ? null : openTabRegistryRef(tenantId, venueId, tabName);
  const orderRef = tenantRef.collection("orders").doc(orderId);
  const actor = actorSnapshot(await auth.getUser(caller.uid));

  return db.runTransaction(async (transaction) => {
    const [venue, table, namedTab, order] = await Promise.all([
      transaction.get(venueRef),
      tableRef == null ? Promise.resolve(null) : transaction.get(tableRef),
      tabRef == null ? Promise.resolve(null) : transaction.get(tabRef),
      transaction.get(orderRef),
    ]);
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (!order.exists || order.data().venueId !== venueId || order.data().status === "closed") {
      throw new HttpsError("failed-precondition", "This order is no longer open at this venue.");
    }
    if ((order.data().tableId ?? null) !== tableId || (order.data().tabName ?? null) !== tabName) {
      throw new HttpsError("failed-precondition", "This order belongs to a different table or named tab.");
    }
    if (tableRef != null && (!table.exists || table.data().venueId !== venueId
        || table.data().currentOrderId !== orderId)) {
      throw new HttpsError("failed-precondition", "The selected table no longer has this open order.");
    }
    if (tabRef != null && (!namedTab.exists || namedTab.data().orderId !== orderId)) {
      throw new HttpsError("failed-precondition", "This named tab is no longer open.");
    }
    const priorLines = Array.isArray(order.data().lines) ? order.data().lines : [];
    const target = priorLines.find((item) => item?.id === lineId);
    if (target == null) {
      throw new HttpsError("not-found", "The draft item is no longer on this order.");
    }
    if (target.isSentToProduction === true) {
      throw new HttpsError("failed-precondition", "Printed items cannot be changed. Use a cancellation or refund.");
    }
    const nextLines = quantity === 0
      ? priorLines.filter((item) => item?.id !== lineId)
      : priorLines.map((item) => item?.id === lineId ? {...item, quantity} : item);
    const hasSentLines = nextLines.some((item) => item?.isSentToProduction === true);
    if (nextLines.length === 0 && tableRef != null) {
      transaction.delete(orderRef);
      transaction.update(tableRef, {
        currentOrderId: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    } else {
      transaction.update(orderRef, {
        status: hasSentLines ? "sent" : "open",
        lines: nextLines,
        updatedAt: FieldValue.serverTimestamp(),
        updatedByActor: actor,
      });
    }
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: quantity === 0 ? "removeOrderDraftLine" : "updateOrderDraftLine",
      venueId,
      orderId,
      tableId,
      tabName,
      lineId,
      quantity,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {orderId, saved: true, removedOrder: nextLines.length === 0 && tableRef != null};
  });
}

async function createTableFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const label = requiredText(data, "label", 80).trim();
  const seats = requiredNonNegativeInteger(data.seats ?? 0, "seats", 1000);
  await requireTenantManager(caller, tenantId);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const tableRef = tenantRef.collection("tables").doc();
  const labelRef = tableLabelRegistryRef(tenantId, venueId, tableLabelKey(label));
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  await db.runTransaction(async (transaction) => {
    const [venue, registeredLabel] = await Promise.all([
      transaction.get(venueRef),
      transaction.get(labelRef),
    ]);
    // Older venues created before the status field was introduced remain
    // operational. Only an explicitly deleting venue is unavailable.
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (registeredLabel.exists) {
      throw new HttpsError("already-exists", "A table with this name already exists at the venue.");
    }
    transaction.create(tableRef, {
      venueId,
      label,
      normalizedLabel: tableLabelKey(label),
      seats,
      createdAt: FieldValue.serverTimestamp(),
      createdByActor: actor,
      updatedAt: FieldValue.serverTimestamp(),
    });
    transaction.create(labelRef, {
      venueId,
      tableId: tableRef.id,
      label,
      createdAt: FieldValue.serverTimestamp(),
    });
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "createTable",
      venueId,
      tableId: tableRef.id,
      label,
      seats,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
  });
  return {id: tableRef.id, label, seats};
}

async function updateTableFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const tableId = requiredText(data, "tableId", 128);
  const label = requiredText(data, "label", 80).trim();
  const seats = requiredNonNegativeInteger(data.seats ?? 0, "seats", 1000);
  await requireTenantManager(caller, tenantId);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const tableRef = tenantRef.collection("tables").doc(tableId);
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  await db.runTransaction(async (transaction) => {
    const table = await transaction.get(tableRef);
    if (!table.exists || table.data().venueId !== venueId) {
      throw new HttpsError("not-found", "The table was not found at this venue.");
    }
    const oldKey = typeof table.data().normalizedLabel === "string"
      ? table.data().normalizedLabel
      : tableLabelKey(table.data().label ?? tableId);
    const newKey = tableLabelKey(label);
    const newLabelRef = tableLabelRegistryRef(tenantId, venueId, newKey);
    if (newKey !== oldKey) {
      const registered = await transaction.get(newLabelRef);
      if (registered.exists && registered.data().tableId !== tableId) {
        throw new HttpsError("already-exists", "A table with this name already exists at the venue.");
      }
      transaction.set(newLabelRef, {
        venueId,
        tableId,
        label,
        updatedAt: FieldValue.serverTimestamp(),
      });
      transaction.delete(tableLabelRegistryRef(tenantId, venueId, oldKey));
    }
    transaction.update(tableRef, {
      label,
      normalizedLabel: newKey,
      seats,
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    });
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "updateTable",
      venueId,
      tableId,
      label,
      seats,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
  });
  return {updated: true};
}

async function deleteTableFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const tableId = requiredText(data, "tableId", 128);
  await requireTenantManager(caller, tenantId);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const tableRef = tenantRef.collection("tables").doc(tableId);
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  await db.runTransaction(async (transaction) => {
    const table = await transaction.get(tableRef);
    if (!table.exists || table.data().venueId !== venueId) {
      throw new HttpsError("not-found", "The table was not found at this venue.");
    }
    if (typeof table.data().currentOrderId === "string") {
      throw new HttpsError("failed-precondition", "Close or move the active order before deleting this table.");
    }
    const key = typeof table.data().normalizedLabel === "string"
      ? table.data().normalizedLabel
      : tableLabelKey(table.data().label ?? tableId);
    transaction.delete(tableRef);
    transaction.delete(tableLabelRegistryRef(tenantId, venueId, key));
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "deleteTable",
      venueId,
      tableId,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
  });
  return {deleted: true};
}

async function updateVenueNotificationSettingsFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const notificationRetentionSeconds = requiredPositiveInteger(
    data.notificationRetentionSeconds,
    "notificationRetentionSeconds",
    60,
  );
  const orderFlowAmberMinutes = requiredPositiveInteger(
    data.orderFlowAmberMinutes,
    "orderFlowAmberMinutes",
    240,
  );
  const orderFlowRedMinutes = requiredPositiveInteger(
    data.orderFlowRedMinutes,
    "orderFlowRedMinutes",
    480,
  );
  if (orderFlowRedMinutes <= orderFlowAmberMinutes) {
    throw new HttpsError("invalid-argument", "The red warning must be later than the amber warning.");
  }
  const businessDayCutoffMinutes = data.businessDayCutoffMinutes == null
    ? null
    : requiredNonNegativeInteger(
        data.businessDayCutoffMinutes,
        "businessDayCutoffMinutes",
        1439,
      );
  await requireTenantManager(caller, tenantId);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  await db.runTransaction(async (transaction) => {
    const venue = await transaction.get(venueRef);
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    const venueData = venue.data();
    const currentCutoff = Number(venueData.businessDayCutoffMinutes ?? 240);
    const safeCurrentCutoff = Number.isInteger(currentCutoff) &&
        currentCutoff >= 0 && currentCutoff < 1440
      ? currentCutoff
      : 240;
    const timeZone = typeof venueData.timeZone === "string"
      ? venueData.timeZone
      : "Europe/London";
    const currentBusinessDate = billBusinessDate(timeZone, safeCurrentCutoff);
    const cutoffRequested = businessDayCutoffMinutes != null;
    const cutoffChanged = cutoffRequested &&
      businessDayCutoffMinutes !== safeCurrentCutoff;
    const existingPendingCutoff = Number(
      venueData.pendingBusinessDayCutoffMinutes,
    );
    const existingPendingEffectiveDate =
      venueData.pendingBusinessDayCutoffEffectiveDate;
    const preservesExistingSchedule = cutoffChanged &&
      existingPendingCutoff === businessDayCutoffMinutes &&
      typeof existingPendingEffectiveDate === "string";
    const cutoffEffectiveDate = cutoffChanged
      ? (preservesExistingSchedule
          ? existingPendingEffectiveDate
          : nextIsoDate(currentBusinessDate))
      : null;
    const cutoffUpdate = !cutoffRequested
      ? {}
      : cutoffChanged
      ? {
          pendingBusinessDayCutoffMinutes: businessDayCutoffMinutes,
          pendingBusinessDayCutoffEffectiveDate: cutoffEffectiveDate,
        }
      : {
          pendingBusinessDayCutoffMinutes: FieldValue.delete(),
          pendingBusinessDayCutoffEffectiveDate: FieldValue.delete(),
        };
    transaction.update(venueRef, {
      notificationRetentionSeconds,
      orderFlowAmberMinutes,
      orderFlowRedMinutes,
      ...cutoffUpdate,
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    });
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "updateVenueNotificationSettings",
      venueId,
      notificationRetentionSeconds,
      orderFlowAmberMinutes,
      orderFlowRedMinutes,
      previousBusinessDayCutoffMinutes: safeCurrentCutoff,
      pendingBusinessDayCutoffMinutes: businessDayCutoffMinutes,
      pendingBusinessDayCutoffEffectiveDate: cutoffEffectiveDate,
      businessDayCutoffChanged: cutoffChanged,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
  });
  return {
    notificationRetentionSeconds,
    orderFlowAmberMinutes,
    orderFlowRedMinutes,
    requestedBusinessDayCutoffMinutes: businessDayCutoffMinutes,
  };
}

function currencyDecimalDigits(currencyCode) {
  switch (currencyCode) {
    case "BIF": case "CLP": case "DJF": case "GNF": case "JPY":
    case "KMF": case "KRW": case "PYG": case "RWF": case "UGX":
    case "VND": case "VUV": case "XAF": case "XOF": case "XPF":
      return 0;
    case "BHD": case "IQD": case "JOD": case "KWD": case "LYD":
    case "OMR": case "TND":
      return 3;
    case "CLF": case "UYW":
      return 4;
    default:
      return 2;
  }
}

function tenToBigInt(power) {
  return 10n ** BigInt(power);
}

/// The rate is recorded as: one major unit of tender currency equals this
/// many major units of the tenant's permanent reporting currency. Keeping the
/// original decimal text plus fixed-scale integer arithmetic avoids floating
/// point errors in historic sales data.
function validExchangeRate(value) {
  if (typeof value !== "string" ||
      !/^(?:0|[1-9]\d{0,8})(?:\.\d{1,6})?$/.test(value.trim())) {
    throw new HttpsError(
      "invalid-argument",
      "exchangeRateToBase must be a positive decimal with up to six decimal places.",
    );
  }
  const text = value.trim();
  const [whole, fraction = ""] = text.split(".");
  const scaled = (BigInt(whole) * 1000000n) + BigInt(fraction.padEnd(6, "0"));
  if (scaled <= 0n) {
    throw new HttpsError("invalid-argument", "exchangeRateToBase must be greater than zero.");
  }
  return {text, scaled};
}

// Percentages are stored as basis points, so 2,000 represents 20.00%.
// Products from before tax support are safely treated as zero-rated until a
// manager sets their rate in Menu management.
function validTaxRateBasisPoints(value) {
  if (value == null) return 0;
  const basisPoints = Number(value);
  if (!Number.isSafeInteger(basisPoints) || basisPoints < 0 || basisPoints > 100000) {
    throw new HttpsError(
      "failed-precondition",
      "A product has an invalid saved tax rate and cannot be sold.",
    );
  }
  return basisPoints;
}

function inclusiveTaxMinor(grossMinor, taxRateBasisPoints) {
  // Prices are tax-inclusive. Half-up rounding keeps gross = net + tax at
  // the bill currency's minor-unit precision.
  return Math.floor(
    ((grossMinor * taxRateBasisPoints) + ((10000 + taxRateBasisPoints) / 2)) /
      (10000 + taxRateBasisPoints),
  );
}

function convertedBaseMinor({amountMinor, tenderCurrencyCode, baseCurrencyCode, exchangeRate}) {
  if (tenderCurrencyCode === baseCurrencyCode) return amountMinor;
  const numerator = BigInt(amountMinor) * exchangeRate.scaled *
    tenToBigInt(currencyDecimalDigits(baseCurrencyCode));
  const denominator = tenToBigInt(currencyDecimalDigits(tenderCurrencyCode)) * 1000000n;
  // Rounds once, half-up, at the reporting currency's minor unit. The rate
  // and converted result are both snapshotted on the bill for auditability.
  const result = (numerator + (denominator / 2n)) / denominator;
  if (result <= 0n || result > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new HttpsError("failed-precondition", "The converted payment amount is outside the supported range.");
  }
  return Number(result);
}

function validClosePayment(value, index, baseCurrencyCode) {
  const payment = requireObject(value);
  const method = requiredText(payment, "method", 40);
  if (!["cash", "cardTerminal"].includes(method)) {
    throw new HttpsError(
      "invalid-argument",
      `payments[${index}].method must be cash or cardTerminal.`,
    );
  }
  const tenderedAmountMinor = requiredPositiveInteger(
    payment.amountMinor,
    `payments[${index}].amountMinor`,
    100000000,
  );
  const cashChangeBaseMinor = payment.cashChangeBaseMinor == null
    ? 0
    : requiredNonNegativeInteger(
      payment.cashChangeBaseMinor,
      `payments[${index}].cashChangeBaseMinor`,
      100000000,
    );
  const tenderedCurrencyCode = requiredText(payment, "currencyCode", 3).toUpperCase();
  if (!supportedCurrencyCodeSet.has(tenderedCurrencyCode)) {
    throw new HttpsError(
      "invalid-argument",
      `payments[${index}].currencyCode must be a supported ISO currency code.`,
    );
  }
  const terminalLabel = optionalText(payment, "terminalLabel", 120) || null;
  const exchangeRateSource = optionalText(payment, "exchangeRateSource", 160) || null;
  const exchangeRatePublishedDate =
    optionalText(payment, "exchangeRatePublishedDate", 80) || null;
  const exchangeRateFetchedAt = optionalText(payment, "exchangeRateFetchedAt", 80) || null;
  if (exchangeRateFetchedAt != null && Number.isNaN(Date.parse(exchangeRateFetchedAt))) {
    throw new HttpsError("invalid-argument", `payments[${index}].exchangeRateFetchedAt is invalid.`);
  }
  if (method === "cardTerminal" && tenderedCurrencyCode !== baseCurrencyCode) {
    throw new HttpsError(
      "failed-precondition",
      "Card terminal payments must use the tenant reporting currency. Foreign tender is recorded as cash.",
    );
  }
  if (method === "cardTerminal" && payment.cardPaymentApproved !== true) {
    throw new HttpsError(
      "failed-precondition",
      "Confirm the card terminal approved this payment before recording it.",
    );
  }
  const exchangeRate = tenderedCurrencyCode === baseCurrencyCode
    ? {text: "1", scaled: 1000000n}
    : validExchangeRate(payment.exchangeRateToBase);
  const tenderedBaseAmountMinor = convertedBaseMinor({
    amountMinor: tenderedAmountMinor,
    tenderCurrencyCode: tenderedCurrencyCode,
    baseCurrencyCode,
    exchangeRate,
  });
  if (method !== "cash" && cashChangeBaseMinor !== 0) {
    throw new HttpsError(
      "invalid-argument",
      `payments[${index}].cashChangeBaseMinor is only valid for cash.`,
    );
  }
  if (cashChangeBaseMinor >= tenderedBaseAmountMinor) {
    throw new HttpsError(
      "failed-precondition",
      "Cash change must be less than the converted cash tender.",
    );
  }
  const baseAmountMinor = tenderedBaseAmountMinor - cashChangeBaseMinor;
  return {
    method,
    tenderedAmountMinor,
    tenderedCurrencyCode,
    exchangeRateToBase: exchangeRate.text,
    tenderedBaseAmountMinor,
    cashChangeBaseMinor,
    baseAmountMinor,
    terminalLabel,
    exchangeRateSource,
    exchangeRatePublishedDate,
    exchangeRateFetchedAt,
    cardPaymentApproved: method === "cardTerminal",
  };
}

function billBusinessDate(timeZone, cutoffMinutes, now = new Date()) {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(now);
  const value = (type) => parts.find((part) => part.type === type)?.value;
  const year = Number(value("year"));
  const month = Number(value("month"));
  const day = Number(value("day"));
  const hour = Number(value("hour"));
  const minute = Number(value("minute"));
  if (![year, month, day, hour, minute].every(Number.isFinite)) {
    throw new HttpsError("failed-precondition", "The venue business date could not be calculated.");
  }
  const localDate = new Date(Date.UTC(year, month - 1, day));
  if ((hour * 60) + minute < cutoffMinutes) {
    localDate.setUTCDate(localDate.getUTCDate() - 1);
  }
  return localDate.toISOString().slice(0, 10);
}

function nextIsoDate(isoDate) {
  const [year, month, day] = isoDate.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  date.setUTCDate(date.getUTCDate() + 1);
  return date.toISOString().slice(0, 10);
}

/// Closes an entire open order against verified payment allocations. A split
/// child can close independently, while the parent table remains occupied
/// until its own remaining amount is settled.
async function closeOrderFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const orderId = requiredText(data, "orderId", 180);
  if (data.printReceipt != null && typeof data.printReceipt !== "boolean") {
    throw new HttpsError("invalid-argument", "printReceipt must be true or false.");
  }
  const printReceipt = data.printReceipt === true;
  const rawPayments = data.payments;
  if (!Array.isArray(rawPayments) || rawPayments.length === 0 || rawPayments.length > 8) {
    throw new HttpsError(
      "invalid-argument",
      "One to eight payment allocations are required.",
    );
  }
  const {roles} = await requireTenantOperationalMember(caller, tenantId);
  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const orderRef = tenantRef.collection("orders").doc(orderId);
  // A deterministic bill ID makes a lost HTTP response safe to retry.
  const billRef = tenantRef.collection("bills").doc(orderId);
  const receiptRouteRef = printReceipt
    ? tenantRef.collection("printerRoutes").doc(`${venueId}_receipt`)
    : null;
  const actor = actorSnapshot(await auth.getUser(caller.uid));

  return db.runTransaction(async (transaction) => {
    const [tenant, venue, order, existingBill, receiptRoute] = await Promise.all([
      transaction.get(tenantRef),
      transaction.get(venueRef),
      transaction.get(orderRef),
      transaction.get(billRef),
      receiptRouteRef == null ? Promise.resolve(null) : transaction.get(receiptRouteRef),
    ]);
    if (!tenant.exists) {
      throw new HttpsError("not-found", "The restaurant was not found.");
    }
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (existingBill.exists) {
      const existing = existingBill.data();
      if (existing.venueId !== venueId || existing.orderId !== orderId) {
        throw new HttpsError("failed-precondition", "This bill ID belongs to different sale data.");
      }
      return {
        billId: existingBill.id,
        totalMinor: existing.totalMinor,
        currencyCode: existing.currencyCode,
        receiptNumber: typeof existing.receiptNumber === "string"
          ? existing.receiptNumber
          : existingBill.id,
        receiptPrintRequested: existing.receiptPrintRequested === true,
        receiptPrintQueued: existing.receiptPrintQueued === true,
        alreadyClosed: true,
      };
    }
    if (!order.exists || order.data().venueId !== venueId || order.data().status === "closed") {
      throw new HttpsError("failed-precondition", "This order is no longer open at this venue.");
    }
    const orderData = order.data();
    const openSplitOrderIds = Array.isArray(orderData.openSplitOrderIds)
      ? orderData.openSplitOrderIds.filter(
        (splitOrderId) => typeof splitOrderId === "string" && splitOrderId.length > 0,
      )
      : [];
    if (openSplitOrderIds.length > 0) {
      throw new HttpsError(
        "failed-precondition",
        "Settle every separate split bill before closing the remaining table bill.",
      );
    }
    const rawLines = Array.isArray(orderData.lines) ? orderData.lines : [];
    if (rawLines.length === 0) {
      throw new HttpsError("failed-precondition", "An empty order cannot be closed.");
    }
    if (rawLines.some((line) => line?.isSentToProduction !== true)) {
      throw new HttpsError(
        "failed-precondition",
        "Send or remove every draft item before closing the bill.",
      );
    }
    const lines = rawLines.map((line, index) => {
      const quantity = Number(line?.quantity);
      const unitPriceMinor = Number(line?.unitPriceMinor);
      if (!Number.isInteger(quantity) || quantity <= 0 ||
          !Number.isSafeInteger(unitPriceMinor) || unitPriceMinor < 0) {
        throw new HttpsError("failed-precondition", `Order line ${index + 1} has invalid saved sale data.`);
      }
      const taxRateBasisPoints = validTaxRateBasisPoints(
        line?.taxRateBasisPoints,
      );
      const taxRateId = typeof line?.taxRateId === "string" ? line.taxRateId : null;
      const taxRateName = typeof line?.taxRateName === "string" &&
          line.taxRateName.trim().length > 0
        ? line.taxRateName.trim()
        : "Zero rate";
      const lineTotalMinor = quantity * unitPriceMinor;
      const taxMinor = inclusiveTaxMinor(lineTotalMinor, taxRateBasisPoints);
      return {
        id: typeof line.id === "string" ? line.id : "",
        productId: typeof line.productId === "string" ? line.productId : "",
        productName: typeof line.productName === "string" ? line.productName : "Menu item",
        quantity,
        unitPriceMinor,
        lineTotalMinor,
        taxRateBasisPoints,
        taxRateId,
        taxRateName,
        taxMinor,
        netMinor: lineTotalMinor - taxMinor,
        productionArea: typeof line.productionArea === "string" ? line.productionArea : "kitchen",
        variantId: typeof line.variantId === "string" ? line.variantId : null,
        variantName: typeof line.variantName === "string" ? line.variantName : null,
        variantPriceDeltaMinor: Number.isSafeInteger(Number(line.variantPriceDeltaMinor))
          ? Number(line.variantPriceDeltaMinor)
          : 0,
        modifierSelections: Array.isArray(line.modifierSelections)
          ? line.modifierSelections
              .filter((selection) => selection != null && typeof selection === "object")
              .map((selection) => ({...selection}))
          : [],
        itemNote: typeof line.itemNote === "string" ? line.itemNote : "",
      };
    });
    const totalMinor = lines.reduce((total, line) => total + line.lineTotalMinor, 0);
    if (!Number.isSafeInteger(totalMinor) || totalMinor <= 0) {
      throw new HttpsError("failed-precondition", "This order has no payable total.");
    }
    const taxByRate = new Map();
    for (const line of lines) {
      const taxKey = line.taxRateId ?? `${line.taxRateName}_${line.taxRateBasisPoints}`;
      const current = taxByRate.get(taxKey) ?? {
        taxRateId: line.taxRateId,
        taxRateName: line.taxRateName,
        taxRateBasisPoints: line.taxRateBasisPoints,
        grossMinor: 0,
        netMinor: 0,
        taxMinor: 0,
      };
      current.grossMinor += line.lineTotalMinor;
      current.netMinor += line.netMinor;
      current.taxMinor += line.taxMinor;
      taxByRate.set(taxKey, current);
    }
    const taxBreakdown = [...taxByRate.values()].sort(
      (left, right) => left.taxRateBasisPoints - right.taxRateBasisPoints,
    );
    const taxTotalMinor = taxBreakdown.reduce(
      (total, entry) => total + entry.taxMinor,
      0,
    );
    const netTotalMinor = totalMinor - taxTotalMinor;
    const currencyCode = String(tenant.data().currencyCode ?? "GBP").toUpperCase();
    const receiptBusiness = receiptBusinessSnapshot(tenant.data());
    const payments = rawPayments.map((payment, index) =>
      validClosePayment(payment, index, currencyCode));
    if (payments.some((payment) => payment.tenderedCurrencyCode !== currencyCode) &&
        !roles.some((role) => role === "owner" || role === "manager")) {
      throw new HttpsError(
        "permission-denied",
        "A manager must enter or approve a foreign-currency exchange rate.",
      );
    }
    const paidMinor = payments.reduce((total, payment) => total + payment.baseAmountMinor, 0);
    if (paidMinor !== totalMinor) {
      throw new HttpsError(
        "failed-precondition",
        "The payment amount must exactly equal the current bill total.",
      );
    }

    const tableId = typeof orderData.tableId === "string" ? orderData.tableId : null;
    const tabName = typeof orderData.tabName === "string" ? orderData.tabName : null;
    const splitFromOrderId = typeof orderData.splitFromOrderId === "string"
      ? orderData.splitFromOrderId
      : null;
    const splitParentRef = splitFromOrderId == null
      ? null
      : tenantRef.collection("orders").doc(splitFromOrderId);
    const splitParent = splitParentRef == null
      ? null
      : await transaction.get(splitParentRef);
    if (splitParentRef != null && (!splitParent?.exists ||
        splitParent.data().venueId !== venueId)) {
      throw new HttpsError("failed-precondition", "The parent table bill is no longer available.");
    }
    const tableRef = tableId == null ? null : tenantRef.collection("tables").doc(tableId);
    const tabRef = tabName == null ? null : openTabRegistryRef(tenantId, venueId, tabName);
    const [table, namedTab] = await Promise.all([
      tableRef == null ? Promise.resolve(null) : transaction.get(tableRef),
      tabRef == null ? Promise.resolve(null) : transaction.get(tabRef),
    ]);
    const timeZone = typeof venue.data().timeZone === "string"
      ? venue.data().timeZone
      : "Europe/London";
    const configuredCutoff = Number(venue.data().businessDayCutoffMinutes ?? 240);
    let cutoffMinutes = Number.isInteger(configuredCutoff) && configuredCutoff >= 0 && configuredCutoff < 1440
      ? configuredCutoff
      : 240;
    let businessDate = billBusinessDate(timeZone, cutoffMinutes);
    const pendingCutoff = Number(venue.data().pendingBusinessDayCutoffMinutes);
    const pendingEffectiveDate = venue.data().pendingBusinessDayCutoffEffectiveDate;
    const pendingIsValid = Number.isInteger(pendingCutoff) &&
      pendingCutoff >= 0 && pendingCutoff < 1440 &&
      typeof pendingEffectiveDate === "string";
    let activatePendingCutoff = false;
    if (pendingIsValid) {
      const candidateBusinessDate = billBusinessDate(timeZone, pendingCutoff);
      if (candidateBusinessDate >= pendingEffectiveDate) {
        cutoffMinutes = pendingCutoff;
        businessDate = candidateBusinessDate;
        activatePendingCutoff = true;
      }
    }
    const receiptNumber = `${businessDate.replaceAll("-", "")}-${orderId.slice(-6).toUpperCase()}`;
    const receiptLines = lines.map((line) => ({...line}));
    const receiptTargetDeviceId = receiptRoute?.exists &&
        typeof receiptRoute.data().primaryDeviceId === "string"
      ? receiptRoute.data().primaryDeviceId
      : null;
    const receiptDeviceRef = receiptTargetDeviceId == null
      ? null
      : tenantRef.collection("devices").doc(receiptTargetDeviceId);
    // Reads must happen before the transaction writes. This separately-routed
    // device is the only printer allowed to receive paid bill totals.
    const receiptDevice = receiptDeviceRef == null
      ? null
      : await transaction.get(receiptDeviceRef);
    // Firestore requires every transaction read to complete before its first
    // write, so promotion of a scheduled cut-off deliberately happens here.
    if (activatePendingCutoff) {
      transaction.update(venueRef, {
        businessDayCutoffMinutes: pendingCutoff,
        pendingBusinessDayCutoffMinutes: FieldValue.delete(),
        pendingBusinessDayCutoffEffectiveDate: FieldValue.delete(),
        businessDayCutoffActivatedAt: FieldValue.serverTimestamp(),
      });
      transaction.create(tenantRef.collection("auditEvents").doc(), {
        action: "activateBusinessDayCutoff",
        venueId,
        businessDayCutoffMinutes: pendingCutoff,
        effectiveBusinessDate: pendingEffectiveDate,
        actor,
        createdAt: FieldValue.serverTimestamp(),
      });
    }
    const receiptPrintQueued = printReceipt &&
      receiptTargetDeviceId != null &&
      activeRouteDevice(receiptDevice, venueId, "receipt");
    const receiptPrintJobId = receiptPrintQueued
      ? `receipt_${orderId}_${receiptTargetDeviceId}`
      : null;

    transaction.create(billRef, {
      venueId,
      orderId,
      status: "closed",
      receiptNumber,
      tableId,
      tableLabel: typeof orderData.tableLabel === "string" ? orderData.tableLabel : null,
      tabName,
      splitFromOrderId,
      splitSequence: Number.isInteger(orderData.splitSequence)
        ? orderData.splitSequence
        : null,
      currencyCode,
      businessDate,
      businessDayCutoffMinutes: cutoffMinutes,
      venueTimeZone: timeZone,
      totalMinor,
      grossTotalMinor: totalMinor,
      netTotalMinor,
      taxTotalMinor,
      taxBreakdown,
      payments,
      receiptPrintRequested: printReceipt,
      receiptPrintQueued,
      receiptPrintJobId,
      receiptBusiness,
      lines: receiptLines,
      openedAt: orderData.openedAt ?? null,
      closedAt: FieldValue.serverTimestamp(),
      closedByActor: actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    if (receiptPrintQueued) {
      transaction.create(tenantRef.collection("printJobs").doc(receiptPrintJobId), {
        venueId,
        targetDeviceId: receiptTargetDeviceId,
        fallbackDeviceId: typeof receiptRoute.data().fallbackDeviceId === "string"
          ? receiptRoute.data().fallbackDeviceId
          : null,
        orderId,
        ticketId: `receipt_${orderId}`,
        productionArea: "receipt",
        status: "queued",
        attempts: 0,
        idempotencyKey: receiptPrintJobId,
        payload: {
          type: "receipt",
          receiptNumber,
          restaurantName: receiptBusiness.name,
          business: receiptBusiness,
          currencyCode,
          businessDate,
          tableLabel: typeof orderData.tableLabel === "string"
            ? orderData.tableLabel
            : null,
          tabName,
          totalMinor,
          netTotalMinor,
          taxTotalMinor,
          taxBreakdown,
          lines: receiptLines,
          payments,
        },
        createdAt: FieldValue.serverTimestamp(),
      });
    }
    transaction.update(orderRef, {
      status: "closed",
      closedAt: FieldValue.serverTimestamp(),
      closedByActor: actor,
      billId: billRef.id,
      businessDate,
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    });
    if (splitParentRef != null && splitParent?.exists) {
      transaction.update(splitParentRef, {
        openSplitOrderIds: FieldValue.arrayRemove(orderId),
        updatedAt: FieldValue.serverTimestamp(),
        updatedByActor: actor,
      });
    }
    if (tableRef != null && table?.exists && table.data().currentOrderId === orderId) {
      transaction.update(tableRef, {
        currentOrderId: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    if (tabRef != null && namedTab?.exists && namedTab.data().orderId === orderId) {
      transaction.delete(tabRef);
    }
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "closeBill",
      venueId,
      orderId,
      billId: billRef.id,
      receiptNumber,
      totalMinor,
      netTotalMinor,
      taxTotalMinor,
      receiptPrintRequested: printReceipt,
      receiptPrintQueued,
      receiptPrintJobId,
      currencyCode,
      splitFromOrderId,
      paymentMethods: payments.map((payment) => payment.method),
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {
      billId: billRef.id,
      totalMinor,
      currencyCode,
      receiptNumber,
      receiptPrintRequested: printReceipt,
      receiptPrintQueued,
      alreadyClosed: false,
    };
  });
}

/// Moves selected already-sent items into a separate payable child order. No
/// stock movement or production ticket is created here: the food/drinks have
/// already been released. Only the financially safe sale allocation changes.
async function splitOrderFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const sourceOrderId = requiredText(data, "orderId", 180);
  const splitOrderId = requiredText(data, "splitOrderId", 180);
  const allocations = validSplitLineAllocations(data.splitLines);
  await requireTenantOperationalMember(caller, tenantId);

  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const sourceOrderRef = tenantRef.collection("orders").doc(sourceOrderId);
  const splitOrderRef = tenantRef.collection("orders").doc(splitOrderId);
  const actor = actorSnapshot(await auth.getUser(caller.uid));

  return db.runTransaction(async (transaction) => {
    const [venue, sourceOrder, existingSplit] = await Promise.all([
      transaction.get(venueRef),
      transaction.get(sourceOrderRef),
      transaction.get(splitOrderRef),
    ]);
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (existingSplit.exists) {
      const splitData = existingSplit.data();
      if (splitData.venueId !== venueId || splitData.splitFromOrderId !== sourceOrderId) {
        throw new HttpsError("failed-precondition", "This split reference belongs to a different order.");
      }
      const existingLines = Array.isArray(splitData.lines) ? splitData.lines : [];
      const totalMinor = existingLines.reduce((total, line) => {
        const quantity = Number(line?.quantity);
        const unitPriceMinor = Number(line?.unitPriceMinor);
        return Number.isInteger(quantity) && Number.isSafeInteger(unitPriceMinor)
          ? total + quantity * unitPriceMinor
          : total;
      }, 0);
      return {
        splitOrderId,
        splitTotalMinor: totalMinor,
        remainingTotalMinor: null,
        alreadySplit: true,
      };
    }
    if (!sourceOrder.exists || sourceOrder.data().venueId !== venueId ||
        sourceOrder.data().status === "closed" ||
        typeof sourceOrder.data().splitFromOrderId === "string") {
      throw new HttpsError(
        "failed-precondition",
        "Only an open main table or named tab can be split.",
      );
    }
    const sourceData = sourceOrder.data();
    const rawLines = Array.isArray(sourceData.lines) ? sourceData.lines : [];
    if (rawLines.length === 0) {
      throw new HttpsError("failed-precondition", "An empty order cannot be split.");
    }
    const sourceLines = rawLines.map((rawLine, index) => {
      const line = requireObject(rawLine);
      const id = requiredText(line, "id", 180);
      const quantity = requiredPositiveInteger(
        line.quantity,
        `order line ${index + 1} quantity`,
        100,
      );
      const unitPriceMinor = Number(line.unitPriceMinor);
      if (!Number.isSafeInteger(unitPriceMinor) || unitPriceMinor < 0 ||
          line.isSentToProduction !== true) {
        throw new HttpsError(
          "failed-precondition",
          "Send every item before creating a separate bill.",
        );
      }
      return {id, quantity, unitPriceMinor, raw: line};
    });
    const sourceLineById = new Map(sourceLines.map((line) => [line.id, line]));
    const allocationByLineId = new Map(allocations.map((allocation) => [
      allocation.lineId,
      allocation.quantity,
    ]));
    for (const allocation of allocations) {
      const sourceLine = sourceLineById.get(allocation.lineId);
      if (sourceLine == null || allocation.quantity > sourceLine.quantity) {
        throw new HttpsError(
          "failed-precondition",
          "One selected item is no longer available in this table bill.",
        );
      }
    }
    const selectedQuantity = allocations.reduce((total, allocation) => total + allocation.quantity, 0);
    const sourceQuantity = sourceLines.reduce((total, line) => total + line.quantity, 0);
    if (selectedQuantity >= sourceQuantity) {
      throw new HttpsError(
        "failed-precondition",
        "Keep at least one item on the main bill, or use Pay to settle the whole table.",
      );
    }
    const splitLines = [];
    const remainingLines = [];
    let splitTotalMinor = 0;
    let remainingTotalMinor = 0;
    for (const [index, sourceLine] of sourceLines.entries()) {
      const splitQuantity = allocationByLineId.get(sourceLine.id) ?? 0;
      const remainingQuantity = sourceLine.quantity - splitQuantity;
      if (splitQuantity > 0) {
        splitLines.push({
          ...sourceLine.raw,
          id: `split-${splitOrderId.slice(-18)}-${index}-${sourceLine.id.slice(-18)}`,
          quantity: splitQuantity,
          splitFromLineId: sourceLine.id,
          isSentToProduction: true,
        });
        splitTotalMinor += splitQuantity * sourceLine.unitPriceMinor;
      }
      if (remainingQuantity > 0) {
        remainingLines.push({...sourceLine.raw, quantity: remainingQuantity});
        remainingTotalMinor += remainingQuantity * sourceLine.unitPriceMinor;
      }
    }
    if (splitLines.length === 0 || remainingLines.length === 0 ||
        !Number.isSafeInteger(splitTotalMinor) || !Number.isSafeInteger(remainingTotalMinor)) {
      throw new HttpsError("failed-precondition", "This split has invalid order totals.");
    }
    const currentSequence = Number(sourceData.splitSequence ?? 0);
    const splitSequence = Number.isInteger(currentSequence) && currentSequence >= 0
      ? currentSequence + 1
      : 1;
    const tableId = typeof sourceData.tableId === "string" ? sourceData.tableId : null;
    const tabName = typeof sourceData.tabName === "string" ? sourceData.tabName : null;
    // A split only applies to the live bill currently attached to this table
    // or named tab. This prevents an old open document from being split after
    // another device has moved or replaced that table's order.
    const tableRef = tableId == null
      ? null
      : tenantRef.collection("tables").doc(tableId);
    const tabRef = tabName == null
      ? null
      : openTabRegistryRef(tenantId, venueId, tabName);
    const [table, namedTab] = await Promise.all([
      tableRef == null ? Promise.resolve(null) : transaction.get(tableRef),
      tabRef == null ? Promise.resolve(null) : transaction.get(tabRef),
    ]);
    if (tableRef != null && (!table?.exists ||
        table.data().venueId !== venueId ||
        table.data().currentOrderId !== sourceOrderId)) {
      throw new HttpsError(
        "failed-precondition",
        "This table is now using a different open order. Refresh and retry.",
      );
    }
    if (tabRef != null && (!namedTab?.exists ||
        namedTab.data().venueId !== venueId ||
        namedTab.data().orderId !== sourceOrderId)) {
      throw new HttpsError(
        "failed-precondition",
        "This named tab is now using a different open order. Refresh and retry.",
      );
    }
    transaction.create(splitOrderRef, {
      venueId,
      tableId,
      tableLabel: typeof sourceData.tableLabel === "string" ? sourceData.tableLabel : null,
      tabName,
      status: "sent",
      openedAt: FieldValue.serverTimestamp(),
      createdByActor: actor,
      lines: splitLines,
      splitFromOrderId: sourceOrderId,
      splitSequence,
      splitCreatedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    });
    transaction.update(sourceOrderRef, {
      lines: remainingLines,
      splitSequence,
      openSplitOrderIds: FieldValue.arrayUnion(splitOrderId),
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    });
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "splitOrder",
      venueId,
      sourceOrderId,
      splitOrderId,
      splitSequence,
      splitTotalMinor,
      remainingTotalMinor,
      itemCount: selectedQuantity,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {
      splitOrderId,
      splitTotalMinor,
      remainingTotalMinor,
      alreadySplit: false,
    };
  });
}

function activeRouteDevice(device, venueId, productionArea) {
  if (!device?.exists) return false;
  const data = device.data();
  return data.venueId === venueId
    && data.active === true
    && Array.isArray(data.productionAreas)
    && data.productionAreas.includes(productionArea);
}

// A failed ticket is never edited or silently deleted. A manager can only
// return it to its original active printer route, and the payload is marked as
// a reprint so kitchen/bar staff can safely recognise a possible duplicate.
async function retryFailedPrintJobFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const jobId = requiredDocumentId(data, "jobId");
  const {roles} = await requireTenantOperationalMember(caller, tenantId);
  if (!roles.some((role) => role === "owner" || role === "manager")) {
    throw new HttpsError(
      "permission-denied",
      "Only a manager can reprint a failed ticket.",
    );
  }

  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const jobRef = tenantRef.collection("printJobs").doc(jobId);
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  return db.runTransaction(async (transaction) => {
    const [venue, job] = await Promise.all([
      transaction.get(venueRef),
      transaction.get(jobRef),
    ]);
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (!job.exists || job.data().venueId !== venueId) {
      throw new HttpsError("not-found", "This failed print job does not belong to the selected venue.");
    }
    const jobData = job.data();
    if (jobData.status !== "failed") {
      throw new HttpsError("failed-precondition", "This print job is no longer failed.");
    }
    if (jobData.fallbackDeliveryStatus === "printed") {
      throw new HttpsError(
        "failed-precondition",
        "A fallback printer already delivered this ticket, so it must not be reprinted.",
      );
    }
    const hasConfiguredFallback = typeof jobData.fallbackDeviceId === "string" &&
      jobData.fallbackDeviceId.length > 0;
    const isFallbackJob = typeof jobData.fallbackFromJobId === "string" &&
      jobData.fallbackFromJobId.length > 0;
    if (hasConfiguredFallback && !isFallbackJob) {
      throw new HttpsError(
        "failed-precondition",
        "This ticket has a fallback printer. Reprint the failed fallback ticket instead, so the original and fallback cannot both print food.",
      );
    }
    const productionArea = typeof jobData.productionArea === "string"
      ? jobData.productionArea
      : "";
    const targetDeviceId = typeof jobData.targetDeviceId === "string"
      ? jobData.targetDeviceId
      : "";
    if (!productionArea || !targetDeviceId) {
      throw new HttpsError("failed-precondition", "This print job has no recoverable printer route.");
    }
    const targetDevice = await transaction.get(
      tenantRef.collection("devices").doc(targetDeviceId),
    );
    if (!activeRouteDevice(targetDevice, venueId, productionArea)) {
      throw new HttpsError(
        "failed-precondition",
        "The original printer route is no longer active. Restore or reconfigure the route before reprinting.",
      );
    }
    const existingPayload = jobData.payload;
    const payload = existingPayload != null &&
        typeof existingPayload === "object" && !Array.isArray(existingPayload)
      ? {...existingPayload}
      : {};
    payload.isReprint = true;
    payload.reprintOfJobId = jobId;
    transaction.update(jobRef, {
      status: "queued",
      attempts: 0,
      payload,
      failureReason: FieldValue.delete(),
      nextAttemptAt: FieldValue.delete(),
      claimedByDeviceId: FieldValue.delete(),
      claimedAt: FieldValue.delete(),
      completedAt: FieldValue.delete(),
      manualRetryCount: FieldValue.increment(1),
      manualRetryRequestedAt: FieldValue.serverTimestamp(),
      manualRetryRequestedByActor: actor,
    });
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "retryFailedPrintJob",
      venueId,
      jobId,
      orderId: typeof jobData.orderId === "string" ? jobData.orderId : null,
      ticketId: typeof jobData.ticketId === "string" ? jobData.ticketId : null,
      productionArea,
      targetDeviceId,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {jobId, queued: true, isReprint: true};
  });
}

// Managers may replace a damaged ticket for five days after successful
// delivery. The completed job remains immutable; a new, visibly marked and
// independently auditable queue job is created for the original printer.
async function reprintPrintedJobFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const jobId = requiredDocumentId(data, "jobId");
  const {roles} = await requireTenantOperationalMember(caller, tenantId);
  if (!roles.some((role) => role === "owner" || role === "manager")) {
    throw new HttpsError(
      "permission-denied",
      "Only a manager can reprint a completed ticket.",
    );
  }

  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const originalRef = tenantRef.collection("printJobs").doc(jobId);
  const reprintRef = tenantRef.collection("printJobs").doc();
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  return db.runTransaction(async (transaction) => {
    const [venue, original] = await Promise.all([
      transaction.get(venueRef),
      transaction.get(originalRef),
    ]);
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (!original.exists || original.data().venueId !== venueId) {
      throw new HttpsError("not-found", "This printed ticket does not belong to the selected venue.");
    }
    const originalData = original.data();
    if (originalData.status !== "printed") {
      throw new HttpsError("failed-precondition", "Only successfully printed tickets can be reprinted from history.");
    }
    const printedAt = originalData.completedAt?.toDate?.() ?? null;
    if (printedAt == null || Date.now() - printedAt.getTime() > 5 * 24 * 60 * 60 * 1000) {
      throw new HttpsError("failed-precondition", "This ticket is outside the five-day reprint window.");
    }
    const productionArea = typeof originalData.productionArea === "string"
      ? originalData.productionArea
      : "";
    const targetDeviceId = typeof originalData.targetDeviceId === "string"
      ? originalData.targetDeviceId
      : "";
    if (!productionArea || !targetDeviceId) {
      throw new HttpsError("failed-precondition", "This ticket has no reusable printer route.");
    }
    const targetDevice = await transaction.get(
      tenantRef.collection("devices").doc(targetDeviceId),
    );
    if (!activeRouteDevice(targetDevice, venueId, productionArea)) {
      throw new HttpsError(
        "failed-precondition",
        "The original printer is no longer active. Restore its route before reprinting.",
      );
    }
    const existingPayload = originalData.payload;
    const payload = existingPayload != null &&
        typeof existingPayload === "object" && !Array.isArray(existingPayload)
      ? {...existingPayload}
      : {};
    payload.isReprint = true;
    payload.reprintOfJobId = jobId;
    transaction.create(reprintRef, {
      venueId,
      targetDeviceId,
      fallbackDeviceId: typeof originalData.fallbackDeviceId === "string"
        ? originalData.fallbackDeviceId
        : null,
      orderId: typeof originalData.orderId === "string" ? originalData.orderId : "",
      ticketId: typeof originalData.ticketId === "string" ? originalData.ticketId : null,
      productionArea,
      status: "queued",
      attempts: 0,
      idempotencyKey: reprintRef.id,
      payload,
      reprintOfJobId: jobId,
      manualReprintRequestedByActor: actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "reprintPrintedJob",
      venueId,
      originalJobId: jobId,
      reprintJobId: reprintRef.id,
      orderId: typeof originalData.orderId === "string" ? originalData.orderId : null,
      ticketId: typeof originalData.ticketId === "string" ? originalData.ticketId : null,
      productionArea,
      targetDeviceId,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {jobId: reprintRef.id, queued: true, isReprint: true};
  });
}

// Queue jobs are retained for audit, never physically deleted. A manager can
// cancel work that has not been claimed by a printer yet. A recently claimed
// job may already be travelling to the printer and remains protected, while a
// claim abandoned for at least five minutes can be cleared by a manager.
// Linked fallback work is cancelled together, so a manager
// never clears the original row only to have the same ticket print elsewhere.
async function cancelPrintJobFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const jobId = requiredDocumentId(data, "jobId");
  const reason = requiredText(data, "reason", 300);
  const {roles} = await requireTenantOperationalMember(caller, tenantId);
  if (!roles.some((role) => role === "owner" || role === "manager")) {
    throw new HttpsError(
      "permission-denied",
      "Only a manager can clear a print job.",
    );
  }

  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const jobRef = tenantRef.collection("printJobs").doc(jobId);
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  return db.runTransaction(async (transaction) => {
    const [venue, job] = await Promise.all([
      transaction.get(venueRef),
      transaction.get(jobRef),
    ]);
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (!job.exists || job.data().venueId !== venueId) {
      throw new HttpsError("not-found", "This print job does not belong to the selected venue.");
    }
    const jobData = job.data();
    const claimTime = jobData.claimedAt?.toDate?.() ??
      jobData.createdAt?.toDate?.() ?? null;
    const staleClaim = jobData.status === "claimed" && claimTime != null &&
      Date.now() - claimTime.getTime() >= 5 * 60 * 1000;
    if (jobData.status !== "queued" &&
        jobData.status !== "failed" &&
        !staleClaim) {
      throw new HttpsError(
        "failed-precondition",
        "Only queued, failed, or printing jobs stuck for at least five minutes can be cleared.",
      );
    }

    const primaryJobId = typeof jobData.fallbackFromJobId === "string" &&
        jobData.fallbackFromJobId.length > 0
      ? jobData.fallbackFromJobId
      : null;
    const linkedJobRef = primaryJobId == null
      ? tenantRef.collection("printJobs").doc(`${jobId}_fallback`)
      : tenantRef.collection("printJobs").doc(primaryJobId);
    const linkedJob = await transaction.get(linkedJobRef);
    if (linkedJob.exists && linkedJob.data().venueId !== venueId) {
      throw new HttpsError("failed-precondition", "The linked printer job belongs to another venue.");
    }
    const linkedData = linkedJob.exists ? linkedJob.data() : null;
    const linkedClaimTime = linkedData?.claimedAt?.toDate?.() ??
      linkedData?.createdAt?.toDate?.() ?? null;
    const linkedIsActiveClaim = linkedData?.status === "claimed" &&
      (linkedClaimTime == null ||
       Date.now() - linkedClaimTime.getTime() < 5 * 60 * 1000);
    if (linkedIsActiveClaim) {
      throw new HttpsError(
        "failed-precondition",
        "A linked fallback job is already printing. Let it finish before clearing this ticket.",
      );
    }

    const cancellation = {
      status: "cancelled",
      cancellationReason: reason,
      cancelledAt: FieldValue.serverTimestamp(),
      cancelledByActor: actor,
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
      nextAttemptAt: FieldValue.delete(),
      claimedByDeviceId: FieldValue.delete(),
      claimedAt: FieldValue.delete(),
    };
    const cancelledJobIds = [jobId];
    transaction.update(jobRef, cancellation);

    if (linkedJob.exists) {
      const linkedData = linkedJob.data();
      const linkedClaimTime = linkedData.claimedAt?.toDate?.() ??
        linkedData.createdAt?.toDate?.() ?? null;
      const linkedStaleClaim = linkedData.status === "claimed" &&
        linkedClaimTime != null &&
        Date.now() - linkedClaimTime.getTime() >= 5 * 60 * 1000;
      if (linkedData.status === "queued" ||
          linkedData.status === "failed" ||
          linkedStaleClaim) {
        transaction.update(linkedJobRef, {
          ...cancellation,
          cancellationReason: `Linked job cleared: ${reason}`,
          cancellationLinkedJobId: jobId,
        });
        cancelledJobIds.push(linkedJob.id);
      }
    }
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "cancelPrintJob",
      venueId,
      jobId,
      cancelledJobIds,
      orderId: typeof jobData.orderId === "string" ? jobData.orderId : null,
      ticketId: typeof jobData.ticketId === "string" ? jobData.ticketId : null,
      productionArea: typeof jobData.productionArea === "string"
        ? jobData.productionArea
        : null,
      reason,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {jobId, cancelledJobIds};
  });
}

// A ticket is deliberately queued to one device at a time.  The original
// device gets three attempts (managed by the client worker); only then does
// this server-side trigger create a separate, idempotent fallback job.  That
// prevents the same ticket printing at both locations while a printer is just
// temporarily slow to connect.
export const enqueueFallbackPrintJob = onDocumentUpdated(
  "tenants/{tenantId}/printJobs/{jobId}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (before == null || after == null) {
      return;
    }

    const tenantId = event.params.tenantId;
    const jobId = event.params.jobId;
    // A fallback completing proves the original ticket was delivered. Store
    // that fact on the failed primary so all tills can stream unresolved jobs
    // only and immediately clear the alarm rather than retaining a false
    // failed-print notification forever.
    if (before.status !== "printed" && after.status === "printed" &&
        typeof after.fallbackFromJobId === "string" && after.fallbackFromJobId.length > 0) {
      const primaryRef = db.doc(`tenants/${tenantId}/printJobs/${after.fallbackFromJobId}`);
      const primary = await primaryRef.get();
      if (primary.exists) {
        await primaryRef.update({
          fallbackDeliveryStatus: "printed",
          fallbackPrintedAt: FieldValue.serverTimestamp(),
        });
      }
      console.info("Fallback print job completed", {
        tenantId,
        jobId,
        failedJobId: after.fallbackFromJobId,
      });
      return;
    }
    if (before.status === "failed" || after.status !== "failed") {
      return;
    }

    const venueId = typeof after.venueId === "string" ? after.venueId : "";
    const productionArea = typeof after.productionArea === "string" ? after.productionArea : "";
    const primaryDeviceId = typeof after.targetDeviceId === "string" ? after.targetDeviceId : "";
    const fallbackDeviceId = typeof after.fallbackDeviceId === "string" ? after.fallbackDeviceId : "";
    if (!venueId || !productionArea || !fallbackDeviceId || fallbackDeviceId === primaryDeviceId) {
      return;
    }

    const tenantRef = db.doc(`tenants/${tenantId}`);
    const fallbackDevice = await tenantRef.collection("devices").doc(fallbackDeviceId).get();
    if (!activeRouteDevice(fallbackDevice, venueId, productionArea)) {
      console.warn("Skipping invalid fallback print device", {
        tenantId,
        jobId,
        venueId,
        productionArea,
        fallbackDeviceId,
      });
      return;
    }

    const fallbackJobId = `${jobId}_fallback`;
    const primaryRef = tenantRef.collection("printJobs").doc(jobId);
    const fallbackRef = tenantRef.collection("printJobs").doc(fallbackJobId);
    const auditRef = tenantRef.collection("auditEvents").doc(`printFallback_${jobId}`);
    const created = await db.runTransaction(async (transaction) => {
      // The manager's clear command updates this primary in a transaction too.
      // Reading it here means a concurrent clear retries this work and prevents
      // an old failure event from reintroducing a cancelled ticket.
      const [currentPrimary, existingFallback] = await Promise.all([
        transaction.get(primaryRef),
        transaction.get(fallbackRef),
      ]);
      if (!currentPrimary.exists || currentPrimary.data().status !== "failed") {
        return false;
      }
      if (existingFallback.exists) return false;
      transaction.create(fallbackRef, {
        venueId,
        targetDeviceId: fallbackDeviceId,
        fallbackDeviceId: null,
        orderId: after.orderId,
        ticketId: after.ticketId,
        productionArea,
        status: "queued",
        attempts: 0,
        idempotencyKey: fallbackJobId,
        payload: after.payload ?? {},
        fallbackFromJobId: jobId,
        createdAt: FieldValue.serverTimestamp(),
      });
      transaction.create(auditRef, {
        action: "queueFallbackPrintJob",
        venueId,
        orderId: after.orderId ?? null,
        ticketId: after.ticketId ?? null,
        productionArea,
        failedJobId: jobId,
        fallbackJobId,
        primaryDeviceId,
        fallbackDeviceId,
        createdAt: FieldValue.serverTimestamp(),
      });
      return true;
    });
    if (created) {
      console.info("Queued fallback print job", {
        tenantId,
        jobId,
        fallbackJobId,
        fallbackDeviceId,
      });
    }
  },
);

async function sendOrderToProductionFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const orderId = requiredText(data, "orderId", 180);
  const tableId = optionalText(data, "tableId", 180) || null;
  const tabName = optionalText(data, "tabName", 80) || null;
  if ((tableId == null) === (tabName == null)) {
    throw new HttpsError(
      "invalid-argument",
      "Choose either a table or a named tab for the order.",
    );
  }
  const rawLines = data.lines;
  if (!Array.isArray(rawLines) || rawLines.length === 0 || rawLines.length > 100) {
    throw new HttpsError("invalid-argument", "One to one hundred new order lines are required.");
  }
  const lines = rawLines.map(validProductionLine);
  if (new Set(lines.map((line) => line.id)).size !== lines.length) {
    throw new HttpsError("invalid-argument", "Each new order line needs a unique ID.");
  }
  const stockOverride = data.stockOverride === true;
  if (data.printRequired != null && typeof data.printRequired !== "boolean") {
    throw new HttpsError("invalid-argument", "printRequired must be true or false.");
  }
  // Older app builds retain their existing behaviour and print by default.
  const printRequired = data.printRequired !== false;
  const {roles} = await requireTenantOperationalMember(caller, tenantId);
  if (stockOverride && !roles.some((role) => role === "owner" || role === "manager")) {
    throw new HttpsError("permission-denied", "Only a manager can override unavailable stock.");
  }

  const tenantRef = db.doc(`tenants/${tenantId}`);
  const venueRef = tenantRef.collection("venues").doc(venueId);
  const tableRef = tableId == null ? null : tenantRef.collection("tables").doc(tableId);
  const tabRef = tabName == null ? null : openTabRegistryRef(tenantId, venueId, tabName);
  const orderRef = tenantRef.collection("orders").doc(orderId);
  const productRefs = new Map(
    [...new Set(lines.map((line) => line.productId))].map((productId) => [
      productId,
      tenantRef.collection("products").doc(productId),
    ]),
  );
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  const tenant = await tenantRef.get();
  const restaurantName = tenant.exists && typeof tenant.data().displayName === "string"
    ? tenant.data().displayName
    : "TABLESIDE POS";

  const result = await db.runTransaction(async (transaction) => {
    const [venue, table, namedTab, existingOrder, ...products] = await Promise.all([
      transaction.get(venueRef),
      tableRef == null ? Promise.resolve(null) : transaction.get(tableRef),
      tabRef == null ? Promise.resolve(null) : transaction.get(tabRef),
      transaction.get(orderRef),
      ...[...productRefs.values()].map((ref) => transaction.get(ref)),
    ]);
    // Older venues created before the status field was introduced remain
    // operational. Only an explicitly deleting venue is unavailable.
    if (!venue.exists || venue.data().status === "deleting") {
      throw new HttpsError("failed-precondition", "The selected venue is not active.");
    }
    if (tableRef != null && (!table.exists || table.data().venueId !== venueId)) {
      throw new HttpsError("failed-precondition", "The selected table is not available at this venue.");
    }
    const currentOrderId = tableRef == null ? null : table.data().currentOrderId;
    if (tableRef != null && typeof currentOrderId === "string" && currentOrderId !== orderId) {
      throw new HttpsError(
        "failed-precondition",
        "This table already has a different open order. Reopen that bill instead.",
      );
    }
    if (tabRef != null && (!namedTab.exists || namedTab.data().orderId !== orderId)) {
      throw new HttpsError(
        "failed-precondition",
        "A different open tab already uses this name. Reopen it instead.",
      );
    }
    const productById = new Map();
    for (const snapshot of products) {
      if (!snapshot.exists) {
        throw new HttpsError("not-found", "A selected menu product no longer exists.");
      }
      if (snapshot.data().venueId !== venueId) {
        throw new HttpsError(
          "failed-precondition",
          "A selected menu product does not belong to this venue.",
        );
      }
      productById.set(snapshot.id, snapshot.data());
    }

    const configuredModifierGroupIdsForOrder = [...new Set(
      [...productById.values()].flatMap((product) =>
        configuredModifierGroupIds(product)),
    )];
    const modifierGroupSnapshots = await Promise.all(
      configuredModifierGroupIdsForOrder.map((groupId) =>
        transaction.get(tenantRef.collection("modifierGroups").doc(groupId))),
    );
    const modifierGroupsById = new Map(
      modifierGroupSnapshots.map((group) => [
        group.id,
        group.exists ? group.data() : null,
      ]),
    );

    const canonicalLines = lines.map((line) => {
      const product = productById.get(line.productId);
      if (product.isAvailable === false) {
        throw new HttpsError("failed-precondition", "A selected product is unavailable.");
      }
      const configuration = canonicalLineConfiguration({
        productData: product,
        modifierGroupsById,
        line,
      });
      const unitPriceMinor = Number(product.priceMinor) + configuration.priceDeltaMinor;
      if (!Number.isSafeInteger(unitPriceMinor) || unitPriceMinor < 0) {
        throw new HttpsError(
          "failed-precondition",
          "A selected product has an invalid stored price and cannot be sold.",
        );
      }
      const stockPerSale = Number(product.stockPerSale ?? 1);
      if (!Number.isFinite(stockPerSale) || stockPerSale <= 0) {
        throw new HttpsError(
          "failed-precondition",
          "A selected product has an invalid stock quantity per sale.",
        );
      }
      const productionArea = product.productionArea === "bar"
        ? "bar"
        : product.productionArea === "dessert"
          ? "dessert"
          : "kitchen";
      const taxRateBasisPoints = validTaxRateBasisPoints(
        product.taxRateBasisPoints,
      );
      return {
        ...line,
        productName: typeof product.name === "string" ? product.name : "Menu item",
        unitPriceMinor,
        productionArea,
        trackStock: product.trackStock === true,
        stockPerSale,
        taxRateBasisPoints,
        taxRateId: typeof product.taxRateId === "string" ? product.taxRateId : null,
        taxRateName: typeof product.taxRateName === "string"
          ? product.taxRateName
          : "Zero rate",
        variantId: configuration.variantId,
        variantName: configuration.variantName,
        variantPriceDeltaMinor: configuration.variantPriceDeltaMinor,
        modifierSelections: configuration.modifierSelections,
        itemNote: configuration.itemNote,
        showOnOrderFlow: product.showOnOrderFlow !== false,
      };
    });
    const groups = new Map();
    for (const line of canonicalLines) {
      const group = groups.get(line.productionArea) ?? [];
      group.push(line);
      groups.set(line.productionArea, group);
    }
    const ticketEntries = [...groups.entries()].map(([area, areaLines]) => {
      const ticketId = `${orderId}_${area}_${areaLines.map((line) => line.id).join("_")}`;
      return {area, lines: areaLines, ticketId, ref: tenantRef.collection("productionTickets").doc(ticketId)};
    });
    const existingTickets = await Promise.all(
      ticketEntries.map((ticket) => transaction.get(ticket.ref)),
    );
    const existingTicketIds = new Set(
      existingTickets.filter((ticket) => ticket.exists).map((ticket) => ticket.id),
    );
    // Route records are read before any transaction writes. A route is only
    // accepted when its target is an active printer device at this same venue.
    const routeEntries = printRequired ? ticketEntries.map((ticket) => ({
      area: ticket.area,
      ref: tenantRef.collection("printerRoutes").doc(`${venueId}_${ticket.area}`),
    })) : [];
    const routeSnapshots = await Promise.all(
      routeEntries.map((route) => transaction.get(route.ref)),
    );
    const routeByArea = new Map(
      routeSnapshots
        .map((snapshot, index) => [routeEntries[index].area, snapshot])
        .filter(([, snapshot]) => snapshot.exists),
    );
    const targetDeviceIds = [...new Set(
      [...routeByArea.values()]
        .map((route) => route.data().primaryDeviceId)
        .filter((deviceId) => typeof deviceId === "string" && deviceId.length > 0),
    )];
    const targetDeviceRefs = new Map(targetDeviceIds.map((deviceId) => [
      deviceId,
      tenantRef.collection("devices").doc(deviceId),
    ]));
    const targetDevices = await Promise.all(
      [...targetDeviceRefs.values()].map((ref) => transaction.get(ref)),
    );
    const deviceById = new Map(
      targetDevices.map((device) => [device.id, device]),
    );

    const tableLabel = tableRef == null
      ? null
      : (typeof table.data().label === "string" ? table.data().label : tableId);
    const priorLines = Array.isArray(existingOrder.data()?.lines) ? existingOrder.data().lines : [];
    const priorLineIds = new Set(
      priorLines.map((line) => (typeof line?.id === "string" ? line.id : "")),
    );
    const canonicalById = new Map(canonicalLines.map((line) => [line.id, line]));
    const sentOrderLine = (line) => ({
      id: line.id,
      productId: line.productId,
      productName: line.productName,
      quantity: line.quantity,
      unitPriceMinor: line.unitPriceMinor,
      productionArea: line.productionArea,
      trackStock: line.trackStock,
      stockPerSale: line.stockPerSale,
      taxRateBasisPoints: line.taxRateBasisPoints,
      taxRateId: line.taxRateId,
      taxRateName: line.taxRateName,
      variantId: line.variantId,
      variantName: line.variantName,
      variantPriceDeltaMinor: line.variantPriceDeltaMinor,
      modifierSelections: line.modifierSelections,
      itemNote: line.itemNote,
      isSentToProduction: true,
    });
    // Draft lines already exist on the order so every device can see them.
    // Sending must promote those same lines to sent rather than treating them
    // as duplicates and silently creating no ticket.
    const mergedOrderLines = [
      ...priorLines.map((line) => {
        const canonical = canonicalById.get(line?.id);
        return canonical == null ? line : sentOrderLine(canonical);
      }),
      ...canonicalLines
        .filter((line) => !priorLineIds.has(line.id))
        .map(sentOrderLine),
    ];
    const hasPriorSentLines = priorLines.some((line) => line?.isSentToProduction === true);
    transaction.set(orderRef, {
      venueId,
      tableId,
      tabName,
      tableLabel,
      status: "sent",
      openedAt: existingOrder.data()?.openedAt ?? FieldValue.serverTimestamp(),
      lastTicketReleasedAt: FieldValue.serverTimestamp(),
      createdByActor: existingOrder.data()?.createdByActor ?? actor,
      lines: mergedOrderLines,
      updatedAt: FieldValue.serverTimestamp(),
      updatedByActor: actor,
    }, {merge: true});
    if (tableRef != null) {
      transaction.update(tableRef, {
        currentOrderId: orderId,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }

    const stockTotals = new Map();
    const printJobIds = [];
    const queuedProductionAreas = new Set();
    const unroutedProductionAreas = new Set();
    for (const ticket of ticketEntries) {
      if (existingTicketIds.has(ticket.ticketId)) continue;
      transaction.create(ticket.ref, {
        venueId,
        orderId,
        reference: orderId.split("-").at(-1) ?? orderId,
        tableLabel,
        tabName,
        productionArea: ticket.area,
        printRequired,
        flowStatus: "newOrder",
        ticketReleasedAt: FieldValue.serverTimestamp(),
        productionItems: ticket.lines.map((line) => ({
          name: line.productName,
          quantity: line.quantity,
          details: productionLineDetails(line),
        })),
        orderFlowItems: ticket.lines
          .filter((line) => line.showOnOrderFlow)
          .map((line) => ({
            name: line.productName,
            quantity: line.quantity,
            details: productionLineDetails(line),
          })),
        showOnOrderFlow: ticket.lines.some((line) => line.showOnOrderFlow),
        hasAllergyAlert: false,
        isDelayed: false,
        createdByActor: actor,
        idempotencyKey: ticket.ticketId,
        createdAt: FieldValue.serverTimestamp(),
      });
      if (printRequired) {
        const route = routeByArea.get(ticket.area);
        const targetDeviceId = route?.data().primaryDeviceId;
        const targetDevice = typeof targetDeviceId === "string"
          ? deviceById.get(targetDeviceId)
          : null;
        if (typeof targetDeviceId === "string"
            && activeRouteDevice(targetDevice, venueId, ticket.area)) {
          const jobId = `${ticket.ticketId}_${targetDeviceId}`;
          transaction.create(tenantRef.collection("printJobs").doc(jobId), {
            venueId,
            targetDeviceId,
            fallbackDeviceId: typeof route.data().fallbackDeviceId === "string"
              ? route.data().fallbackDeviceId
              : null,
            orderId,
            ticketId: ticket.ticketId,
            productionArea: ticket.area,
            status: "queued",
            attempts: 0,
            idempotencyKey: jobId,
            payload: {
              type: "production",
              ticketId: ticket.ticketId,
              restaurantName,
              reference: orderId.split("-").at(-1) ?? orderId,
              productionArea: ticket.area,
              tableLabel,
              tabName,
              isAddition: hasPriorSentLines,
              createdByName: actor.displayName ?? actor.email ?? "",
              lines: ticket.lines.map((line) => ({
                name: line.productName,
                quantity: line.quantity,
                details: productionLineDetails(line),
              })),
            },
            createdAt: FieldValue.serverTimestamp(),
          });
          printJobIds.push(jobId);
          queuedProductionAreas.add(ticket.area);
        } else {
          unroutedProductionAreas.add(ticket.area);
        }
      }
      // The till deliberately keeps every tap as its own order line so staff
      // can see the latest addition. Several lines can therefore represent
      // the same tracked product on one ticket. Aggregate before creating
      // stock movements: Firestore correctly rejects two `create` writes to
      // the same ticket/product movement document in one transaction.
      const ticketStockTotals = new Map();
      for (const line of ticket.lines.filter((item) => item.trackStock)) {
        const quantity = line.quantity * line.stockPerSale;
        ticketStockTotals.set(
          line.productId,
          (ticketStockTotals.get(line.productId) ?? 0) + quantity,
        );
      }
      for (const [productId, quantity] of ticketStockTotals.entries()) {
        stockTotals.set(productId, (stockTotals.get(productId) ?? 0) + quantity);
        const movementRef = tenantRef.collection("stockMovements")
          .doc(`${ticket.ticketId}_${productId}`);
        transaction.create(movementRef, {
          venueId,
          orderId,
          ticketId: ticket.ticketId,
          productId,
          quantity: -quantity,
          reason: "productionTicketReleased",
          createdByActor: actor,
          createdAt: FieldValue.serverTimestamp(),
        });
      }
    }
    for (const [productId, quantity] of stockTotals.entries()) {
      const product = productById.get(productId);
      const onHand = Number(product.stockOnHand ?? 0);
      if (onHand < quantity && !stockOverride) {
        throw new HttpsError(
          "failed-precondition",
          "One or more tracked products are sold out. A manager may record an audited stock override.",
        );
      }
      transaction.update(productRefs.get(productId), {
        stockOnHand: FieldValue.increment(-quantity),
        lastStockMovementAt: FieldValue.serverTimestamp(),
      });
    }
    transaction.create(tenantRef.collection("auditEvents").doc(), {
      action: "sendOrderToProduction",
      venueId,
      orderId,
      ticketIds: ticketEntries.map((ticket) => ticket.ticketId),
      printJobIds,
      queuedProductionAreas: [...queuedProductionAreas],
      unroutedProductionAreas: [...unroutedProductionAreas],
      stockOverride,
      printRequired,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {
      ticketIds: ticketEntries.map((ticket) => ticket.ticketId),
      printJobIds,
      queuedProductionAreas: [...queuedProductionAreas],
      unroutedProductionAreas: [...unroutedProductionAreas],
      stockOverride,
      printRequired,
    };
  });
  return result;
}

const permittedOrderFlowTransitions = Object.freeze({
  newOrder: ["newOrder", "preparing"],
  preparing: ["preparing", "ready"],
  ready: ["ready", "collected"],
  collected: ["collected", "served"],
  served: ["served"],
  cancelled: ["cancelled"],
  voided: ["voided"],
});

async function updateProductionTicketFor(caller, rawData) {
  const data = requireObject(rawData);
  const tenantId = requiredText(data, "tenantId", 128);
  const venueId = requiredText(data, "venueId", 128);
  const ticketId = requiredDocumentId(data, "ticketId");
  const flowStatus = requiredText(data, "flowStatus", 32);
  if (!Object.hasOwn(permittedOrderFlowTransitions, flowStatus)) {
    throw new HttpsError("invalid-argument", "The production status is not recognised.");
  }
  if (typeof data.isDelayed !== "boolean") {
    throw new HttpsError("invalid-argument", "isDelayed must be true or false.");
  }
  const membership = await db.doc(`tenants/${tenantId}/members/${caller.uid}`).get();
  const roles = membership.exists && Array.isArray(membership.data().roles)
    ? membership.data().roles
    : [];
  if (!membership.exists || membership.data().active === false
      || !roles.some((role) => ["owner", "manager", "waiter", "cashier", "kitchen"].includes(role))) {
    throw new HttpsError("permission-denied", "Your role cannot update production tickets.");
  }
  const ticketRef = db.doc(`tenants/${tenantId}/productionTickets/${ticketId}`);
  const actor = actorSnapshot(await auth.getUser(caller.uid));
  return db.runTransaction(async (transaction) => {
    const ticket = await transaction.get(ticketRef);
    if (!ticket.exists || ticket.data().venueId !== venueId) {
      throw new HttpsError("not-found", "The production ticket was not found at this venue.");
    }
    const currentStatus = typeof ticket.data().flowStatus === "string"
      ? ticket.data().flowStatus
      : "newOrder";
    const permitted = permittedOrderFlowTransitions[currentStatus] ?? [];
    if (!permitted.includes(flowStatus)) {
      throw new HttpsError(
        "failed-precondition",
        "This ticket must move through the normal production sequence.",
      );
    }
    transaction.update(ticketRef, {
      flowStatus,
      isDelayed: data.isDelayed,
      flowUpdatedAt: FieldValue.serverTimestamp(),
      flowUpdatedByActor: actor,
    });
    transaction.create(db.collection(`tenants/${tenantId}/auditEvents`).doc(), {
      action: "updateProductionTicket",
      venueId,
      ticketId,
      fromStatus: currentStatus,
      toStatus: flowStatus,
      isDelayed: data.isDelayed,
      actor,
      createdAt: FieldValue.serverTimestamp(),
    });
    return {updated: true};
  });
}

async function invokePlatformAction(action, caller, data) {
  switch (action) {
    case "bootstrapPlatformAdmin":
      return bootstrapPlatformAdminFor(caller);
    case "listAuthUsers":
      return listAuthUsersFor(caller, data);
    case "listTenants":
      return listTenantsFor(caller);
    case "listSupportedTimeZones":
      return listSupportedTimeZonesFor(caller);
    case "listSupportedCurrencies":
      return listSupportedCurrenciesFor(caller);
    case "listTenantVenues":
      return listTenantVenuesFor(caller, data);
    case "listUserMemberships":
      return listUserMembershipsFor(caller, data);
    case "createTenant":
      return createTenantFor(caller, data);
    case "updateTenant":
      return updateTenantFor(caller, data);
    case "createVenue":
      return createVenueFor(caller, data);
    case "updateVenue":
      return updateVenueFor(caller, data);
    case "deleteVenue":
      return deleteVenueFor(caller, data);
    case "createStaffUser":
      return createStaffUserFor(caller, data);
    case "assignUserToTenant":
      return assignUserToTenantFor(caller, data);
    case "retireStaffUser":
      return retireStaffUserFor(caller, data);
    case "setPlatformAdmin":
      return setPlatformAdminFor(caller, data);
    default:
      throw new HttpsError("not-found", "That platform action does not exist.");
  }
}

async function invokePosAction(action, caller, data) {
  const sessionBootstrapActions = new Set([
    "listVenuePinStaff", "setOwnStaffPin", "verifyStaffPin",
  ]);
  const actingCaller = sessionBootstrapActions.has(action)
    ? caller
    : await actingCallerFromStaffSession(caller, data);
  switch (action) {
    case "listVenuePinStaff":
      return listVenuePinStaffFor(caller, data);
    case "setOwnStaffPin":
      return setOwnStaffPinFor(caller, data);
    case "verifyStaffPin":
      return verifyStaffPinFor(caller, data);
    case "unlockStaffPin":
      return unlockStaffPinFor(caller, data);
    case "openNamedTab":
      return openNamedTabFor(actingCaller, data);
    case "addOrderDraftLine":
      return addOrderDraftLineFor(actingCaller, data);
    case "updateOrderDraftLine":
      return updateOrderDraftLineFor(actingCaller, data);
    case "createTable":
      return createTableFor(actingCaller, data);
    case "updateTable":
      return updateTableFor(actingCaller, data);
    case "deleteTable":
      return deleteTableFor(actingCaller, data);
    case "updateVenueNotificationSettings":
      return updateVenueNotificationSettingsFor(actingCaller, data);
    case "manageMenuConfiguration":
      return manageMenuConfigurationFor(actingCaller, data);
    case "manageVenueConfiguration":
      return manageVenueConfigurationFor(actingCaller, data);
    case "uploadTenantLogo":
      return uploadTenantLogoFor(actingCaller, data);
    case "lookupExchangeRate":
      return lookupExchangeRateFor(actingCaller, data);
    case "sendOrderToProduction":
      return sendOrderToProductionFor(actingCaller, data);
    case "closeOrder":
      return closeOrderFor(actingCaller, data);
    case "splitOrder":
      return splitOrderFor(actingCaller, data);
    case "updateProductionTicket":
      return updateProductionTicketFor(actingCaller, data);
    case "retryFailedPrintJob":
      return retryFailedPrintJobFor(actingCaller, data);
    case "reprintPrintedJob":
      return reprintPrintedJobFor(actingCaller, data);
    case "cancelPrintJob":
      return cancelPrintJobFor(actingCaller, data);
    default:
      throw new HttpsError("not-found", "That POS action does not exist.");
  }
}

async function callerFromHttpRequest(request) {
  const header = request.get("authorization") ?? "";
  if (!header.startsWith("Bearer ")) {
    throw new HttpsError("unauthenticated", "A Firebase ID token is required.");
  }
  try {
    const token = await auth.verifyIdToken(header.substring(7));
    return {uid: token.uid, token};
  } catch (_) {
    throw new HttpsError("unauthenticated", "The Firebase ID token is invalid or expired.");
  }
}

// Verifies App Check for TableSide's custom HTTP APIs. Firestore and Storage
// have their own App Check enforcement in the Firebase console. Monitor mode
// provides server-side evidence before enforcement rejects older clients.
async function verifyAppCheckFromHttpRequest(request, endpointName) {
  const token = request.get("X-Firebase-AppCheck") ?? "";
  if (token.trim().length === 0) {
    console.warn(`App Check missing for ${endpointName}.`);
    if (requireAppCheck.value()) {
      throw new HttpsError("unauthenticated", "A valid Firebase App Check token is required.");
    }
    return null;
  }
  try {
    const claims = await appCheck.verifyToken(token);
    console.info(`App Check verified for ${endpointName}.`);
    return claims;
  } catch (error) {
    console.warn(`App Check verification failed for ${endpointName}.`, error);
    if (requireAppCheck.value()) {
      throw new HttpsError("unauthenticated", "The Firebase App Check token is invalid.");
    }
    return null;
  }
}

function httpStatusFor(error) {
  switch (error.code) {
    case "invalid-argument": return 400;
    case "unauthenticated": return 401;
    case "permission-denied": return 403;
    case "not-found": return 404;
    case "already-exists": return 409;
    case "failed-precondition": return 412;
    case "unavailable": return 503;
    default: return 500;
  }
}

function diagnosticErrorMessage(error) {
  // Preserve a concise, actionable message for authenticated debug clients.
  // Stacks remain server-only, but swallowing the message turns every server
  // fault into an indistinguishable HTTP 500 and makes safe POS recovery
  // impossible for staff.
  if (error != null && typeof error === "object" &&
      typeof error.message === "string" && error.message.trim().length > 0) {
    return error.message.trim().slice(0, 300);
  }
  return "An unexpected server error occurred.";
}

// This endpoint is used by the Flutter app because the FlutterFire Functions
// plugin does not yet support Windows. It verifies the Firebase ID token on
// every call, then uses exactly the same handlers as the callable functions.
export const platformAdminApi = onRequest({cors: true}, async (request, response) => {
  try {
    if (request.method !== "POST") {
      response.status(405).json({error: {code: "method-not-allowed", message: "Use POST."}});
      return;
    }
    await verifyAppCheckFromHttpRequest(request, "platformAdminApi");
    const body = requireObject(request.body);
    const action = requiredText(body, "action", 80);
    const data = requireObject(body.data ?? {});
    const caller = await callerFromHttpRequest(request);
    const result = await invokePlatformAction(action, caller, data);
    response.status(200).json({data: result});
  } catch (error) {
    if (error instanceof HttpsError) {
      response.status(httpStatusFor(error)).json({
        error: {code: error.code, message: error.message},
      });
      return;
    }
    console.error("Unexpected platform administration error", error);
    response.status(500).json({
      error: {code: "internal", message: "The platform action could not be completed."},
    });
  }
});

// Privileged POS mutations use this small authenticated HTTP surface for the
// same Windows-compatible reason as platformAdminApi.  It treats all client
// prices, stock and printer-facing data as untrusted and derives the canonical
// values from Firestore inside the command handler.
export const posApi = onRequest({cors: true}, async (request, response) => {
  let action = "unknown";
  try {
    if (request.method !== "POST") {
      response.status(405).json({error: {code: "method-not-allowed", message: "Use POST."}});
      return;
    }
    await verifyAppCheckFromHttpRequest(request, "posApi");
    const body = requireObject(request.body);
    action = requiredText(body, "action", 80);
    const data = requireObject(body.data ?? {});
    const caller = await callerFromHttpRequest(request);
    const result = await invokePosAction(action, caller, data);
    response.status(200).json({data: result});
  } catch (error) {
    if (error instanceof HttpsError) {
      response.status(httpStatusFor(error)).json({
        error: {code: error.code, message: error.message},
      });
      return;
    }
    const message = diagnosticErrorMessage(error);
    console.error("Unexpected POS command error", {
      action,
      code: error != null && typeof error === "object" ? error.code ?? null : null,
      message,
      stack: error != null && typeof error === "object" ? error.stack ?? null : null,
    });
    response.status(500).json({
      error: {
        code: "internal",
        message: `The POS action could not be completed: ${message}`,
      },
    });
  }
});

// Callable variants remain available for non-Windows clients and tests.
export const bootstrapPlatformAdmin = onCall((request) =>
  bootstrapPlatformAdminFor(callerFromCall(request)));
export const listAuthUsers = onCall((request) =>
  listAuthUsersFor(callerFromCall(request), request.data));
export const listTenants = onCall((request) =>
  listTenantsFor(callerFromCall(request)));
export const listSupportedTimeZones = onCall((request) =>
  listSupportedTimeZonesFor(callerFromCall(request)));
export const listSupportedCurrencies = onCall((request) =>
  listSupportedCurrenciesFor(callerFromCall(request)));
export const listTenantVenues = onCall((request) =>
  listTenantVenuesFor(callerFromCall(request), request.data));
export const listUserMemberships = onCall((request) =>
  listUserMembershipsFor(callerFromCall(request), request.data));
export const createTenant = onCall((request) =>
  createTenantFor(callerFromCall(request), request.data));
export const updateTenant = onCall((request) =>
  updateTenantFor(callerFromCall(request), request.data));
export const createVenue = onCall((request) =>
  createVenueFor(callerFromCall(request), request.data));
export const updateVenue = onCall((request) =>
  updateVenueFor(callerFromCall(request), request.data));
export const listVenuePinStaff = onCall((request) =>
  listVenuePinStaffFor(callerFromCall(request), request.data));
export const setOwnStaffPin = onCall((request) =>
  setOwnStaffPinFor(callerFromCall(request), request.data));
export const verifyStaffPin = onCall((request) =>
  verifyStaffPinFor(callerFromCall(request), request.data));
export const deleteVenue = onCall((request) =>
  deleteVenueFor(callerFromCall(request), request.data));
export const createStaffUser = onCall((request) =>
  createStaffUserFor(callerFromCall(request), request.data));
export const assignUserToTenant = onCall((request) =>
  assignUserToTenantFor(callerFromCall(request), request.data));
export const retireStaffUser = onCall((request) =>
  retireStaffUserFor(callerFromCall(request), request.data));
export const setPlatformAdmin = onCall((request) =>
  setPlatformAdminFor(callerFromCall(request), request.data));
export const createTable = onCall((request) =>
  createTableFor(callerFromCall(request), request.data));
export const updateTable = onCall((request) =>
  updateTableFor(callerFromCall(request), request.data));
export const deleteTable = onCall((request) =>
  deleteTableFor(callerFromCall(request), request.data));
