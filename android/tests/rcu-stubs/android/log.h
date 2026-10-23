#pragma once
#define ANDROID_LOG_INFO 4
static inline int __android_log_write(int, const char*, const char* text) {
    testLog(text);
    return 0;
}
