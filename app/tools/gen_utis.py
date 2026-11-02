#!/usr/bin/env python3
"""Generate Info.plist UTI declarations from Config/uti-table.json.

Writes:
  Vitrine/Info.plist                 — host app plist with UTExportedTypeDeclarations / UTImportedTypeDeclarations
  Extensions/<Name>/Info.plist        — each Quick Look extension plist with its QLSupportedContentTypes
Run from app/: python3 -I tools/gen_utis.py   (idempotent; rerun whenever the table changes)
"""
import json, plistlib, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
table = json.loads((ROOT / "Config" / "uti-table.json").read_text())
prefix = table["prefix"]

def decl(entry, exported):
    ident = f"{prefix}.{entry['id']}" if exported else entry["id"]
    d = {
        "UTTypeIdentifier": ident,
        "UTTypeDescription": entry["desc"],
        "UTTypeConformsTo": entry["conforms"],
    }
    if entry["ext"]:
        d["UTTypeTagSpecification"] = {"public.filename-extension": entry["ext"]}
    return d

exported = [decl(e, True) for e in table["exported"]]
imported = [decl(e, False) for e in table["imported"]]

host = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleDisplayName": "Vitrine",
    "CFBundleExecutable": "$(EXECUTABLE_NAME)",
    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "$(PRODUCT_NAME)",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
    "LSApplicationCategoryType": "public.app-category.utilities",
    "LSUIElement": False,
    "NSHumanReadableCopyright": "Vitrine",
    "NSPrincipalClass": "NSApplication",
    "UTExportedTypeDeclarations": exported,
    "UTImportedTypeDeclarations": imported,
}
(ROOT / "Vitrine").mkdir(exist_ok=True)
# Only the type declarations are this script's: every other key already in the host plist (the Finder Services of
# G-18, URL schemes, document types) is kept, so regenerating never deletes what was added by hand.
host_path = ROOT / "Vitrine" / "Info.plist"
if host_path.exists():
    with open(host_path, "rb") as f:
        existing = plistlib.load(f)
    for key, value in existing.items():
        if key not in ("UTExportedTypeDeclarations", "UTImportedTypeDeclarations"):
            host[key] = value
    host["UTExportedTypeDeclarations"] = host.pop("UTExportedTypeDeclarations")
    host["UTImportedTypeDeclarations"] = host.pop("UTImportedTypeDeclarations")
with open(host_path, "wb") as f:
    plistlib.dump(host, f, sort_keys=False)

for name, types in table["extensions"].items():
    resolved = [f"{prefix}.{t[1:]}" if t.startswith("$") else t for t in types]
    plist = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": f"Vitrine {name}",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundlePackageType": "XPC!",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
        "NSExtension": {
            "NSExtensionAttributes": {
                "QLSupportedContentTypes": resolved,
                "QLSupportsSearchableItems": False,
            },
            "NSExtensionPointIdentifier": "com.apple.quicklook.preview",
            "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).PreviewViewController",
        },
    }
    d = ROOT / "Extensions" / name
    d.mkdir(parents=True, exist_ok=True)
    with open(d / "Info.plist", "wb") as f:
        plistlib.dump(plist, f, sort_keys=False)
    print(f"{name}: {len(resolved)} content types")
# Thumbnail extensions (S-18; folders first, O-3): Finder's icons, drawn by QLThumbnailProvider.
for name, types in table.get("thumbnailExtensions", {}).items():
    resolved = [f"{prefix}.{t[1:]}" if t.startswith("$") else t for t in types]
    plist = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": f"Vitrine {name}",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundlePackageType": "XPC!",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSMinimumSystemVersion": "$(MACOSX_DEPLOYMENT_TARGET)",
        "NSExtension": {
            "NSExtensionAttributes": {
                "QLSupportedContentTypes": resolved,
                "QLThumbnailMinimumDimension": 16,
            },
            "NSExtensionPointIdentifier": "com.apple.quicklook.thumbnail",
            "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ThumbnailProvider",
        },
    }
    d = ROOT / "Extensions" / name
    d.mkdir(parents=True, exist_ok=True)
    with open(d / "Info.plist", "wb") as f:
        plistlib.dump(plist, f, sort_keys=False)
    print(f"{name} (thumbnails): {len(resolved)} content types")
# The Spotlight importer (S-19, X-8): a legacy CFPlugIn bundle in Contents/Library/Spotlight. Its factory UUID is
# fixed; changing it would leave a second registration behind on every Mac that had the old one.
if "spotlightImporter" in table:
    resolved = [f"{prefix}.{t[1:]}" if t.startswith("$") else t for t in table["spotlightImporter"]["types"]]
    factory = "259BBBEC-E6B8-4EBD-9939-F33AE9E4AD29"
    plist = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundlePackageType": "BNDL",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "CFBundleDocumentTypes": [{"CFBundleTypeRole": "MDImporter", "LSItemContentTypes": resolved}],
        "CFPlugInDynamicRegistration": "NO",
        "CFPlugInFactories": {factory: "VitrineImporterFactory"},
        # kMDImporterTypeID (MDImporter.h)
        "CFPlugInTypes": {"8B08C4BF-415B-11D8-B3F9-0003936726FC": [factory]},
    }
    d = ROOT / "Spotlight"
    d.mkdir(parents=True, exist_ok=True)
    with open(d / "Info.plist", "wb") as f:
        plistlib.dump(plist, f, sort_keys=False)
    print(f"Spotlight importer: {len(resolved)} content types")
print(f"host: {len(exported)} exported, {len(imported)} imported UTIs")
