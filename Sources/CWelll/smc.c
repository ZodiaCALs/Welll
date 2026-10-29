#include "CWelll.h"

#include <mach/mach.h>
#include <string.h>

/* The parameter block the AppleSMC user client expects. It must be exactly 80 bytes. */

enum {
    kCSMCUserClientSelector = 2, /* kSMCHandleYPCEvent */
    kCSMCReadBytes = 5,
    kCSMCWriteBytes = 6,
    kCSMCReadKeyInfo = 9,
};

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} CSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} CSMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} CSMCKeyInfoData;

typedef struct {
    uint32_t key;
    CSMCVersion version;
    CSMCPLimitData pLimitData;
    CSMCKeyInfoData keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} CSMCParam;

_Static_assert(sizeof(CSMCParam) == 80, "AppleSMC expects an 80-byte parameter block");

static int CSMCMapReturn(kern_return_t result) {
    if (result == KERN_SUCCESS) return CSMC_OK;
    if (result == kIOReturnNotPrivileged) return CSMC_ERR_NOT_PRIVILEGED;
    if (result == kIOReturnNotFound) return CSMC_ERR_NOT_FOUND;
    return CSMC_ERR_IO;
}

static int CSMCCall(io_connect_t connection, CSMCParam *input, CSMCParam *output) {
    size_t outputSize = sizeof(CSMCParam);
    kern_return_t result = IOConnectCallStructMethod(connection, kCSMCUserClientSelector,
                                                     input, sizeof(CSMCParam),
                                                     output, &outputSize);
    return CSMCMapReturn(result);
}

int CSMCOpen(io_connect_t *connection) {
    if (connection == NULL) return CSMC_ERR_BAD_ARGUMENT;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) return CSMC_ERR_NOT_FOUND;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return CSMCMapReturn(result);
}

void CSMCClose(io_connect_t connection) {
    if (connection != IO_OBJECT_NULL) IOServiceClose(connection);
}

int CSMCGetKeyInfo(io_connect_t connection, uint32_t key, CSMCKeyInfo *info) {
    if (info == NULL) return CSMC_ERR_BAD_ARGUMENT;
    CSMCParam input;
    CSMCParam output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key;
    input.data8 = kCSMCReadKeyInfo;

    int status = CSMCCall(connection, &input, &output);
    if (status != CSMC_OK) return status;
    if (output.result != 0) return CSMC_ERR_NOT_FOUND;

    info->dataSize = output.keyInfo.dataSize;
    info->dataType = output.keyInfo.dataType;
    info->dataAttributes = output.keyInfo.dataAttributes;
    return CSMC_OK;
}

int CSMCReadKey(io_connect_t connection, uint32_t key, uint8_t *bytes, uint32_t capacity, uint32_t *size) {
    if (bytes == NULL || size == NULL) return CSMC_ERR_BAD_ARGUMENT;
    CSMCKeyInfo info;
    int status = CSMCGetKeyInfo(connection, key, &info);
    if (status != CSMC_OK) return status;
    if (info.dataSize == 0 || info.dataSize > 32 || info.dataSize > capacity) return CSMC_ERR_BAD_ARGUMENT;

    CSMCParam input;
    CSMCParam output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key;
    input.keyInfo.dataSize = info.dataSize;
    input.data8 = kCSMCReadBytes;

    status = CSMCCall(connection, &input, &output);
    if (status != CSMC_OK) return status;
    if (output.result != 0) return CSMC_ERR_SMC;

    memcpy(bytes, output.bytes, info.dataSize);
    *size = info.dataSize;
    return CSMC_OK;
}

int CSMCWriteKey(io_connect_t connection, uint32_t key, const uint8_t *bytes, uint32_t size) {
    if (bytes == NULL) return CSMC_ERR_BAD_ARGUMENT;
    CSMCKeyInfo info;
    int status = CSMCGetKeyInfo(connection, key, &info);
    if (status != CSMC_OK) return status;
    if (size == 0 || size > 32 || size != info.dataSize) return CSMC_ERR_BAD_ARGUMENT;

    CSMCParam input;
    CSMCParam output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key;
    input.keyInfo.dataSize = size;
    input.data8 = kCSMCWriteBytes;
    memcpy(input.bytes, bytes, size);

    status = CSMCCall(connection, &input, &output);
    if (status != CSMC_OK) return status;
    if (output.result != 0) return CSMC_ERR_SMC;
    return CSMC_OK;
}
