// Vitrine's Spotlight importer (S-19, X-8): the CFPlugIn shell Spotlight loads from Vitrine.app/Contents/Library/
// Spotlight. Spotlight asks the factory for an object implementing the importer interface (MDImporter.h) and calls
// ImporterImportData once per file; the work is VitrineSpotlightImport in Import.swift. Reference counting follows
// CFPlugInCOM.h. roadmap: S-19

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreServices/CoreServices.h>
#include <stdbool.h>
#include <stdlib.h>

/// Must equal the factory UUID in Info.plist (tools/gen_utis.py writes it).
#define VITRINE_IMPORTER_FACTORY "259BBBEC-E6B8-4EBD-9939-F33AE9E4AD29"

extern bool VitrineSpotlightImport(CFMutableDictionaryRef attributes, CFStringRef contentType, CFStringRef path);

typedef struct {
    MDImporterInterfaceStruct *interface;
    CFUUIDRef factoryID;
    UInt32 refCount;
} VitrineImporter;

static HRESULT ImporterQueryInterface(void *instance, REFIID iid, LPVOID *ppv);
static ULONG ImporterAddRef(void *instance);
static ULONG ImporterRelease(void *instance);

static Boolean ImporterImportData(void *instance, CFMutableDictionaryRef attributes, CFStringRef contentType, CFStringRef path) {
    (void)instance;
    return VitrineSpotlightImport(attributes, contentType, path) ? TRUE : FALSE;
}

static MDImporterInterfaceStruct importerInterface = {
    NULL, ImporterQueryInterface, ImporterAddRef, ImporterRelease, ImporterImportData,
};

static VitrineImporter *ImporterAllocate(CFUUIDRef factoryID) {
    VitrineImporter *importer = malloc(sizeof(VitrineImporter));
    if (importer == NULL) return NULL;
    importer->interface = &importerInterface;
    importer->factoryID = CFRetain(factoryID);
    CFPlugInAddInstanceForFactory(factoryID);
    importer->refCount = 1;
    return importer;
}

static void ImporterDeallocate(VitrineImporter *importer) {
    CFUUIDRef factoryID = importer->factoryID;
    free(importer);
    if (factoryID) {
        CFPlugInRemoveInstanceForFactory(factoryID);
        CFRelease(factoryID);
    }
}

static HRESULT ImporterQueryInterface(void *instance, REFIID iid, LPVOID *ppv) {
    CFUUIDRef asked = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, iid);
    HRESULT result = E_NOINTERFACE;
    *ppv = NULL;
    if (CFEqual(asked, kMDImporterInterfaceID) || CFEqual(asked, IUnknownUUID)) {
        ImporterAddRef(instance);
        *ppv = instance;
        result = S_OK;
    }
    CFRelease(asked);
    return result;
}

static ULONG ImporterAddRef(void *instance) {
    VitrineImporter *importer = instance;
    return ++importer->refCount;
}

static ULONG ImporterRelease(void *instance) {
    VitrineImporter *importer = instance;
    if (--importer->refCount == 0) {
        ImporterDeallocate(importer);
        return 0;
    }
    return importer->refCount;
}

/// Named in Info.plist's CFPlugInFactories.
void *VitrineImporterFactory(CFAllocatorRef allocator, CFUUIDRef typeID) {
    (void)allocator;
    if (!CFEqual(typeID, kMDImporterTypeID)) return NULL;
    CFUUIDRef factoryID = CFUUIDCreateFromString(kCFAllocatorDefault, CFSTR(VITRINE_IMPORTER_FACTORY));
    VitrineImporter *importer = ImporterAllocate(factoryID);
    CFRelease(factoryID);
    return importer;
}
