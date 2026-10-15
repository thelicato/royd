/*
 * royd early display bootstrap.
 *
 * Runtime display values are written by the OCI entrypoint before Android init
 * starts. This helper validates that file during early-init and publishes the
 * values as vendor properties before graphics services are started.
 */
#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <cutils/properties.h>

#define ROYD_CONFIG_PATH "/royd-runtime.conf"
#define ROYD_LINE_MAX 128

struct display_config {
    int width;
    int height;
    int dpi;
    int fps;
};

enum config_field {
    CONFIG_WIDTH = 1u << 0,
    CONFIG_HEIGHT = 1u << 1,
    CONFIG_DPI = 1u << 2,
    CONFIG_FPS = 1u << 3,
    CONFIG_RESOURCE_PROFILE = 1u << 4,
    CONFIG_DISPLAY_FIELDS = CONFIG_WIDTH | CONFIG_HEIGHT | CONFIG_DPI | CONFIG_FPS,
};

static void log_line(const char* level, const char* message) {
    FILE* stream = fopen(strcmp(level, "warning") == 0 ? "/proc/1/fd/2" : "/proc/1/fd/1", "w");
    if (stream == NULL) {
        return;
    }
    fprintf(stream, "[royd] %s%s%s\n", strcmp(level, "warning") == 0 ? "warning: " : "", message,
            "");
    fclose(stream);
}

static int parse_positive(const char* value, int maximum, int* output) {
    char* end = NULL;
    long parsed;

    if (value == NULL || *value == '\0') {
        return -1;
    }
    for (const unsigned char* digit = (const unsigned char*)value; *digit != '\0'; ++digit) {
        if (!isdigit(*digit)) {
            return -1;
        }
    }
    errno = 0;
    parsed = strtol(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed <= 0 || parsed > maximum) {
        return -1;
    }
    *output = (int)parsed;
    return 0;
}

static void defaults(struct display_config* config) {
    char profile[PROPERTY_VALUE_MAX] = {0};
    property_get("ro.vendor.royd.hal_profile", profile, "graphical");
    if (strcmp(profile, "headless") == 0) {
        config->width = 64;
        config->height = 64;
        config->dpi = 72;
        config->fps = 5;
        return;
    }
    config->width = 540;
    config->height = 960;
    config->dpi = 240;
    config->fps = 30;
}

static int apply_line(struct display_config* config, char* line, unsigned int* seen) {
    char* equals = strchr(line, '=');
    int value = 0;
    int maximum = 0;
    int* target = NULL;
    unsigned int field;

    if (equals == NULL) {
        return -1;
    }
    *equals = '\0';
    ++equals;

    if (strcmp(line, "ROYD_WIDTH") == 0) {
        field = CONFIG_WIDTH;
        target = &config->width;
        maximum = 16384;
    } else if (strcmp(line, "ROYD_HEIGHT") == 0) {
        field = CONFIG_HEIGHT;
        target = &config->height;
        maximum = 16384;
    } else if (strcmp(line, "ROYD_DPI") == 0) {
        field = CONFIG_DPI;
        target = &config->dpi;
        maximum = 2000;
    } else if (strcmp(line, "ROYD_FPS") == 0) {
        field = CONFIG_FPS;
        target = &config->fps;
        maximum = 1000;
    } else if (strcmp(line, "ROYD_RESOURCE_PROFILE") == 0) {
        field = CONFIG_RESOURCE_PROFILE;
        // This is metadata for the display reader, not a source of memory policy.
        if (strcmp(equals, "low-memory") != 0 && strcmp(equals, "performance") != 0) {
            return -1;
        }
    } else {
        return -1;
    }

    if ((*seen & field) != 0 || (target != NULL && parse_positive(equals, maximum, &value) != 0)) {
        return -1;
    }
    if (target != NULL) {
        *target = value;
    }
    *seen |= field;
    return 0;
}

// Return one complete bounded line, EOF, or an error. Reject embedded NUL bytes.
static int read_config_line(FILE* file, char* line, size_t capacity) {
    size_t length = 0;
    int character;
    while ((character = fgetc(file)) != EOF && character != '\n') {
        if (character == '\0' || length == capacity - 1) {
            return -1;
        }
        line[length++] = (char)character;
    }
    if (ferror(file)) {
        return -1;
    }
    if (character == EOF && length == 0) {
        return 0;
    }
    if (length > 0 && line[length - 1] == '\r') {
        --length;
    }
    line[length] = '\0';
    return 1;
}

static int load_config(struct display_config* config) {
    FILE* file = fopen(ROYD_CONFIG_PATH, "r");
    char line[ROYD_LINE_MAX];
    struct display_config parsed = *config;
    unsigned int seen = 0;
    int status;

    if (file == NULL) {
        return -1;
    }
    while ((status = read_config_line(file, line, sizeof(line))) > 0) {
        if (line[0] == '\0') {
            continue;
        }
        if (apply_line(&parsed, line, &seen) != 0) {
            status = -1;
            break;
        }
    }
    const int close_status = fclose(file);
    if (status < 0 || close_status != 0 || (seen & CONFIG_DISPLAY_FIELDS) != CONFIG_DISPLAY_FIELDS) {
        return -1;
    }
    *config = parsed;
    return 0;
}

static int set_int_property(const char* name, int value) {
    char text[32];
    snprintf(text, sizeof(text), "%d", value);
    return property_set(name, text);
}

int main(void) {
    struct display_config config;
    char message[160];

    defaults(&config);
    if (load_config(&config) != 0) {
        log_line("warning", "display: runtime config missing or invalid, using profile defaults");
    } else {
        log_line("info", "display: runtime configuration validated");
    }

    if (set_int_property("vendor.royd.display.width", config.width) != 0 ||
        set_int_property("vendor.royd.display.height", config.height) != 0 ||
        set_int_property("vendor.royd.display.dpi", config.dpi) != 0 ||
        set_int_property("vendor.royd.display.fps", config.fps) != 0 ||
        property_set("vendor.royd.display.ready", "1") != 0) {
        log_line("warning", "display: failed to publish early display properties");
        return 1;
    }

    snprintf(message, sizeof(message), "display: early configuration %dx%d @ %d dpi, %d fps", config.width,
             config.height, config.dpi, config.fps);
    log_line("info", message);
    return 0;
}
