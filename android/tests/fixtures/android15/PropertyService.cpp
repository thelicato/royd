/*
 * Copyright (C) 2007 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Selected pinned Android 15 init functions, including preceding repository patches.

class SocketConnection {
  public:
    bool GetSourceContext(std::string* source_context) const {
        char* c_source_context = nullptr;
        if (getpeercon(socket_.get(), &c_source_context) != 0) {
            return false;
        }
        *source_context = c_source_context;
        freecon(c_source_context);
        return true;
    }
};

static bool CheckMacPerms(const std::string& name, const char* target_context,
                          const char* source_context, const ucred& cr) {
    if (!target_context || !source_context) {
        return false;
    }

    PropertyAuditData audit_data;

    audit_data.name = name.c_str();
    audit_data.cr = &cr;

    auto lock = std::lock_guard{selinux_check_access_lock};
    return selinux_check_access(source_context, target_context, "property_service", "set",
                                &audit_data) == 0;
}

uint32_t CheckPermissions(const std::string& name, const std::string& value,
                          const std::string& source_context, const ucred& cr, std::string* error) {
    if (!IsLegalPropertyName(name)) {
        *error = "Illegal property name";
        return PROP_ERROR_INVALID_NAME;
    }

    if (StartsWith(name, "ctl.")) {
        if (!CheckControlPropertyPerms(name, value, source_context, cr)) {
            *error = StringPrintf("Invalid permissions to perform '%s' on '%s'", name.c_str() + 4,
                                  value.c_str());
            return PROP_ERROR_HANDLE_CONTROL_MESSAGE;
        }

        return PROP_SUCCESS;
    }

    const char* target_context = nullptr;
    const char* type = nullptr;
    property_info_area->GetPropertyInfo(name.c_str(), &target_context, &type);

    if (!CheckMacPerms(name, target_context, source_context.c_str(), cr)) {
        *error = "SELinux permission check failed";
        return PROP_ERROR_PERMISSION_DENIED;
    }

    if (!CheckType(type, value)) {
        *error = StringPrintf("Property type check failed, value doesn't match expected type '%s'",
                              (type ?: "(null)"));
        return PROP_ERROR_INVALID_VALUE;
    }

    return PROP_SUCCESS;
}

static std::optional<uint32_t> PropertySet(const std::string& name, const std::string& value,
                                           SocketConnection* socket, std::string* error) {
    size_t valuelen = value.size();

    if (!IsLegalPropertyName(name)) {
        *error = "Illegal property name";
        return {PROP_ERROR_INVALID_NAME};
    }

    if (auto result = IsLegalPropertyValue(name, value); !result.ok()) {
        *error = result.error().message();
        return {PROP_ERROR_INVALID_VALUE};
    }

    if (name == "sys.powerctl") {
        // No action here - NotifyPropertyChange will trigger the appropriate action, and since this
        // can come to the second thread, we mustn't call out to the __system_property_* functions
        // which support multiple readers but only one mutator.
    } else {
        prop_info* pi = (prop_info*)__system_property_find(name.c_str());
        if (pi != nullptr) {
            // ro.* properties are actually "write-once".
            if (StartsWith(name, "ro.")) {
                *error = "Read-only property was already set";
                return {PROP_ERROR_READ_ONLY_PROPERTY};
            }

            __system_property_update(pi, value.c_str(), valuelen);
        } else {
            int rc = __system_property_add(name.c_str(), name.size(), value.c_str(), valuelen);
            if (rc < 0) {
                *error = "__system_property_add failed";
                return {PROP_ERROR_SET_FAILED};
            }
        }

        // Don't write properties to disk until after we have read all default
        // properties to prevent them from being overwritten by default values.
        bool need_persist = StartsWith(name, "persist.") || StartsWith(name, "next_boot.");
        if (socket && persistent_properties_loaded && need_persist) {
            if (persist_write_thread) {
                persist_write_thread->Write(name, value, std::move(*socket));
                return {};
            }
            WritePersistentProperty(name, value);
        }
    }

    NotifyPropertyChange(name, value);
    return {PROP_SUCCESS};
}

bool CheckControlPropertyPerms(const std::string& name, const std::string& value,
                               const std::string& source_context, const ucred& cr) {
    // We check the legacy method first but these properties are dontaudit, so we only log an audit
    // if the newer method fails as well.  We only do this with the legacy ctl. properties.
    if (name == "ctl.start" || name == "ctl.stop" || name == "ctl.restart") {
        // The legacy permissions model is that ctl. properties have their name ctl.<action> and
        // their value is the name of the service to apply that action to.  Permissions for these
        // actions are based on the service, so we must create a fake name of ctl.<service> to
        // check permissions.
        auto control_string_legacy = "ctl." + value;
        const char* target_context_legacy = nullptr;
        const char* type_legacy = nullptr;
        property_info_area->GetPropertyInfo(control_string_legacy.c_str(), &target_context_legacy,
                                            &type_legacy);

        if (CheckMacPerms(control_string_legacy, target_context_legacy, source_context.c_str(), cr)) {
            return true;
        }
    }

    auto control_string_full = name + "$" + value;
    const char* target_context_full = nullptr;
    const char* type_full = nullptr;
    property_info_area->GetPropertyInfo(control_string_full.c_str(), &target_context_full,
                                        &type_full);

    return CheckMacPerms(control_string_full, target_context_full, source_context.c_str(), cr);
}

std::optional<uint32_t> HandlePropertySet(const std::string& name, const std::string& value,
                                          const std::string& source_context, const ucred& cr,
                                          SocketConnection* socket, std::string* error) {
    if (auto ret = CheckPermissions(name, value, source_context, cr, error); ret != PROP_SUCCESS) {
        return {ret};
    }

    if (StartsWith(name, "ctl.")) {
        return {SendControlMessage(name.c_str() + 4, value, cr.pid, socket, error)};
    }

    // sys.powerctl is a special property that is used to make the device reboot.  We want to log
    // any process that sets this property to be able to accurately blame the cause of a shutdown.
    if (name == "sys.powerctl") {
        std::string cmdline_path = StringPrintf("proc/%d/cmdline", cr.pid);
        std::string process_cmdline;
        std::string process_log_string;
        if (ReadFileToString(cmdline_path, &process_cmdline)) {
            // Since cmdline is null deliminated, .c_str() conveniently gives us just the process
            // path.
            process_log_string = StringPrintf(" (%s)", process_cmdline.c_str());
        }
        LOG(INFO) << "Received sys.powerctl='" << value << "' from pid: " << cr.pid
                  << process_log_string;
        if (value == "reboot,userspace") {
            *error = "Userspace reboot is deprecated.";
            return {PROP_ERROR_INVALID_VALUE};
        }
    }

    // If a process other than init is writing a non-empty value, it means that process is
    // requesting that init performs a restorecon operation on the path specified by 'value'.
    // We use a thread to do this restorecon operation to prevent holding up init, as it may take
    // a long time to complete.
    if (name == kRestoreconProperty && cr.pid != 1 && !value.empty()) {
        static AsyncRestorecon async_restorecon;
        async_restorecon.TriggerRestorecon(value);
        return {PROP_SUCCESS};
    }

    return PropertySet(name, value, socket, error);
}

static void handle_property_set_fd(int fd) {
    static constexpr uint32_t kDefaultSocketTimeout = 2000; /* ms */

    int s = accept4(fd, nullptr, nullptr, SOCK_CLOEXEC);
    if (s == -1) {
        return;
    }

    ucred cr;
    socklen_t cr_size = sizeof(cr);
    if (getsockopt(s, SOL_SOCKET, SO_PEERCRED, &cr, &cr_size) < 0) {
        close(s);
        PLOG(ERROR) << "sys_prop: unable to get SO_PEERCRED";
        return;
    }

    SocketConnection socket(s, cr);
    uint32_t timeout_ms = kDefaultSocketTimeout;

    uint32_t cmd = 0;
    if (!socket.RecvUint32(&cmd, &timeout_ms)) {
        PLOG(ERROR) << "sys_prop: error while reading command from the socket";
        socket.SendUint32(PROP_ERROR_READ_CMD);
        return;
    }

    switch (cmd) {
    case PROP_MSG_SETPROP: {
        char prop_name[PROP_NAME_MAX];
        char prop_value[PROP_VALUE_MAX];

        if (!socket.RecvChars(prop_name, PROP_NAME_MAX, &timeout_ms) ||
            !socket.RecvChars(prop_value, PROP_VALUE_MAX, &timeout_ms)) {
          PLOG(ERROR) << "sys_prop(PROP_MSG_SETPROP): error while reading name/value from the socket";
          return;
        }

        prop_name[PROP_NAME_MAX-1] = 0;
        prop_value[PROP_VALUE_MAX-1] = 0;

        std::string source_context;
        if (!socket.GetSourceContext(&source_context)) {
            PLOG(ERROR) << "Unable to set property '" << prop_name << "': getpeercon() failed";
            return;
        }

        const auto& cr = socket.cred();
        std::string error;
        auto result = HandlePropertySetNoSocket(prop_name, prop_value, source_context, cr, &error);
        if (result != PROP_SUCCESS) {
            LOG(ERROR) << "Unable to set property '" << prop_name << "' from uid:" << cr.uid
                       << " gid:" << cr.gid << " pid:" << cr.pid << ": " << error;
        }

        break;
      }

    case PROP_MSG_SETPROP2: {
        std::string name;
        std::string value;
        if (!socket.RecvString(&name, &timeout_ms) ||
            !socket.RecvString(&value, &timeout_ms)) {
          PLOG(ERROR) << "sys_prop(PROP_MSG_SETPROP2): error while reading name/value from the socket";
          socket.SendUint32(PROP_ERROR_READ_DATA);
          return;
        }

        std::string source_context;
        if (!socket.GetSourceContext(&source_context)) {
            PLOG(ERROR) << "Unable to set property '" << name << "': getpeercon() failed";
            socket.SendUint32(PROP_ERROR_PERMISSION_DENIED);
            return;
        }

        // HandlePropertySet takes ownership of the socket if the set is handled asynchronously.
        const auto& cr = socket.cred();
        std::string error;
        auto result = HandlePropertySet(name, value, source_context, cr, &socket, &error);
        if (!result) {
            // Result will be sent after completion.
            return;
        }
        if (*result != PROP_SUCCESS) {
            LOG(ERROR) << "Unable to set property '" << name << "' from uid:" << cr.uid
                       << " gid:" << cr.gid << " pid:" << cr.pid << ": " << error;
        }
        socket.SendUint32(*result);
        break;
      }

    default:
        LOG(ERROR) << "sys_prop: invalid command " << cmd;
        socket.SendUint32(PROP_ERROR_INVALID_CMD);
        break;
    }
}
