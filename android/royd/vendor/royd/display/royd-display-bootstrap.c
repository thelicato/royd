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

static int apply_line(struct display_config* config, char* line) {
    char* equals = strchr(line, '=');
    int value;
    int maximum;
    int* target;

    if (equals == NULL) {
        return -1;
    }
    *equals = '\0';
    ++equals;
    equals[strcspn(equals, "\r\n")] = '\0';

    if (strcmp(line, "ROYD_WIDTH") == 0) {
        target = &config->width;
        maximum = 16384;
    } else if (strcmp(line, "ROYD_HEIGHT") == 0) {
        target = &config->height;
        maximum = 16384;
    } else if (strcmp(line, "ROYD_DPI") == 0) {
        target = &config->dpi;
        maximum = 2000;
    } else if (strcmp(line, "ROYD_FPS") == 0) {
        target = &config->fps;
        maximum = 1000;
    } else {
        return -1;
    }

    if (parse_positive(equals, maximum, &value) != 0) {
        return -1;
    }
    *target = value;
    return 0;
}

static int load_config(struct display_config* config) {
    FILE* file = fopen(ROYD_CONFIG_PATH, "r");
    char line[ROYD_LINE_MAX];
    int seen = 0;

    if (file == NULL) {
        return -1;
    }
    while (fgets(line, sizeof(line), file) != NULL) {
        if (line[0] == '\0' || line[0] == '\n') {
            continue;
        }
        if (apply_line(config, line) != 0) {
            fclose(file);
            return -1;
        }
        ++seen;
    }
    fclose(file);
    return seen == 4 ? 0 : -1;
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
