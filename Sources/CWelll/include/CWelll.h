#ifndef CWELLL_H
#define CWELLL_H

#include <stdint.h>
#include <IOKit/IOKitLib.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * AppleSMC
 * ------------------------------------------------------------------------- */

#define CSMC_OK                 0
#define CSMC_ERR_NOT_FOUND      1
#define CSMC_ERR_BAD_ARGUMENT   2
#define CSMC_ERR_NOT_PRIVILEGED 3
#define CSMC_ERR_IO             4
#define CSMC_ERR_SMC            5

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} CSMCKeyInfo;

/* Opens a connection to the AppleSMC service. */
int CSMCOpen(io_connect_t *connection);

/* Closes a connection returned by CSMCOpen. */
void CSMCClose(io_connect_t connection);

/* Looks up the size and type of `key` (a big-endian four-character code). */
int CSMCGetKeyInfo(io_connect_t connection, uint32_t key, CSMCKeyInfo *info);

/* Reads `key` into `bytes` (at least `capacity` long); the number of bytes read goes to `size`. */
int CSMCReadKey(io_connect_t connection, uint32_t key, uint8_t *bytes, uint32_t capacity, uint32_t *size);

/* Writes exactly `size` bytes to `key`. Needs root, and `size` must match the key. */
int CSMCWriteKey(io_connect_t connection, uint32_t key, const uint8_t *bytes, uint32_t size);

/* ---------------------------------------------------------------------------
 * macOS Charge Limit (System Settings > Battery), through the private
 * PowerUISmartChargeClient class. Flags return 1, 0, or -1 when unknown.
 * ------------------------------------------------------------------------- */

int CPUIAvailable(void);
int CPUIIsSupported(void);
int CPUIIsEnabled(void);
/* The configured limit (80...100), or -1 when it can't be read. */
int CPUIGetLimit(void);
/* Sets the limit. Values outside 80...100 are refused before they reach macOS. */
int CPUISetLimit(int percent, char *error, int errorLength);
int CPUIEnable(char *error, int errorLength);
int CPUIDisable(char *error, int errorLength);

#ifdef __cplusplus
}
#endif

#endif
