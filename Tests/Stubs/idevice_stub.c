#include "../../Vendor/idevice/idevice.h"
#include "idevice_stub.h"

static int clear_calls, set_calls, failed_sets, failed_connections;
#define HANDLE(type) ((struct type *)(uintptr_t)1)
#define ERROR_HANDLE HANDLE(IdeviceFfiError)

void stub_reset(void) { clear_calls = set_calls = failed_sets = failed_connections = 0; }
void stub_fail_next_sets(int count) { failed_sets = count; }
void stub_fail_next_connections(int count) { failed_connections = count; }
int stub_clear_calls(void) { return clear_calls; }
int stub_set_calls(void) { return set_calls; }

struct IdeviceFfiError *rp_pairing_file_read(const char *path, struct RpPairingFileHandle **out) {
    *out = HANDLE(RpPairingFileHandle); return NULL;
}
void rp_pairing_file_free(struct RpPairingFileHandle *handle) {}
void idevice_error_free(struct IdeviceFfiError *error) {}
void location_simulation_free(struct LocationSimulationHandle *handle) {}
void remote_server_free(struct RemoteServerHandle *handle) {}
void adapter_free(struct AdapterHandle *handle) {}
void rsd_handshake_free(struct RsdHandshakeHandle *handle) {}

struct IdeviceFfiError *tunnel_create_rppairing(
    const idevice_sockaddr *addr, idevice_socklen_t addr_len, const char *hostname,
    struct RpPairingFileHandle *pairing, const char *(*pin_callback)(void *), void *context,
    struct AdapterHandle **adapter, struct RsdHandshakeHandle **handshake) {
    if (failed_connections > 0) { failed_connections--; return ERROR_HANDLE; }
    *adapter = HANDLE(AdapterHandle); *handshake = HANDLE(RsdHandshakeHandle); return NULL;
}
struct IdeviceFfiError *remote_server_connect_rsd(struct AdapterHandle *adapter,
    struct RsdHandshakeHandle *handshake, struct RemoteServerHandle **server) {
    *server = HANDLE(RemoteServerHandle); return NULL;
}
struct IdeviceFfiError *location_simulation_new(struct RemoteServerHandle *server,
    struct LocationSimulationHandle **simulation) {
    *simulation = HANDLE(LocationSimulationHandle); return NULL;
}
struct IdeviceFfiError *location_simulation_set(struct LocationSimulationHandle *simulation,
    double latitude, double longitude) {
    set_calls++;
    if (failed_sets > 0) { failed_sets--; return ERROR_HANDLE; }
    return NULL;
}
struct IdeviceFfiError *location_simulation_clear(struct LocationSimulationHandle *simulation) {
    clear_calls++; return NULL;
}
