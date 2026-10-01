#include <stdint.h>
#include <dbus/dbus.h>

// libdbus exposes most constants as cast-expression macros, which clang does
// not import into Swift. Materialize the subset the Linux shell uses.
static const int32_t CDBusBusTypeSession = DBUS_BUS_SESSION;
static const int32_t CDBusNameFlagDoNotQueue = DBUS_NAME_FLAG_DO_NOT_QUEUE;
static const int32_t CDBusNameFlagAllowReplacement = DBUS_NAME_FLAG_ALLOW_REPLACEMENT;
static const int32_t CDBusRequestNameReplyPrimaryOwner = DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER;
static const int32_t CDBusRequestNameReplyAlreadyOwner = DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER;
static const int32_t CDBusRequestNameReplyExists = DBUS_REQUEST_NAME_REPLY_EXISTS;
static const int32_t CDBusTypeString = DBUS_TYPE_STRING;
static const int32_t CDBusTypeBoolean = DBUS_TYPE_BOOLEAN;
static const int32_t CDBusTypeInt32 = DBUS_TYPE_INT32;
static const int32_t CDBusTypeUint32 = DBUS_TYPE_UINT32;
static const int32_t CDBusTypeArray = DBUS_TYPE_ARRAY;
static const int32_t CDBusTypeVariant = DBUS_TYPE_VARIANT;
static const int32_t CDBusTypeDictEntry = DBUS_TYPE_DICT_ENTRY;
static const int32_t CDBusMessageTypeSignal = DBUS_MESSAGE_TYPE_SIGNAL;
static const int32_t CDBusMessageTypeMethodCall = DBUS_MESSAGE_TYPE_METHOD_CALL;

static const char *const CDBusErrorFailed = DBUS_ERROR_FAILED;
