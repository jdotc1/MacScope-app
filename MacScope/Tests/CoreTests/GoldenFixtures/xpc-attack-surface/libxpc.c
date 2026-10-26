#include <xpc/xpc.h>
static void incoming(xpc_connection_t peer) {
    xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
        (void)xpc_dictionary_get_string(event, "action");
    });
    xpc_connection_resume(peer);
}
int main(void) {
    xpc_connection_t listener = xpc_connection_create_mach_service(
        "com.example.fixture.events", 0, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) { incoming(peer); });
    xpc_connection_resume(listener);
    xpc_main(incoming);
    return 0;
}
