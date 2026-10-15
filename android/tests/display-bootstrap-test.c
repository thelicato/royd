/* Execute the production bootstrap with controlled property and file interfaces. */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static FILE* config_stream;
static int open_error, close_error, read_error, read_position, read_failure_at = -1;
static int property_failure_at = -1, properties, validated, fallback, publish_errors;
static const char* hal_profile = "graphical";
static char published[5][92];
static FILE* mock_fopen(const char* path, const char* mode);
static int mock_fgetc(FILE* file);
static int mock_ferror(FILE* file);
static int mock_fclose(FILE* file);

#define fopen mock_fopen
#define fgetc mock_fgetc
#define ferror mock_ferror
#define fclose mock_fclose
#define main bootstrap_main
#include "../royd/vendor/royd/display/royd-display-bootstrap.c"
#undef main
#undef fopen
#undef fgetc
#undef ferror
#undef fclose

#define CHECK(value) do { \
    if (!(value)) { \
        fprintf(stderr, "display bootstrap check failed at %d: %s\n", __LINE__, #value); \
        exit(1); \
    } \
} while (0)

static FILE* mock_fopen(const char* path, const char* mode) {
    if (strcmp(path, "/royd-runtime.conf") == 0) {
        CHECK(strcmp(mode, "r") == 0);
        if (open_error) { errno = open_error; return NULL; }
        CHECK(config_stream != NULL);
        return config_stream;
    }
    CHECK(strcmp(path, "/proc/1/fd/1") == 0 || strcmp(path, "/proc/1/fd/2") == 0);
    CHECK(strcmp(mode, "w") == 0);
    FILE* file = tmpfile();
    CHECK(file != NULL);
    return file;
}

static int mock_fgetc(FILE* file) {
    CHECK(file == config_stream);
    if (read_position++ == read_failure_at) { read_error = 1; errno = EIO; return EOF; }
    return fgetc(file);
}

static int mock_ferror(FILE* file) { return read_error || ferror(file); }

static int mock_fclose(FILE* file) {
    if (file == config_stream) {
        config_stream = NULL;
        CHECK(fclose(file) == 0);
        return close_error ? EOF : 0;
    }
    char text[256] = {0};
    rewind(file);
    CHECK(fread(text, 1, sizeof(text) - 1, file) > 0);
    if (strstr(text, "display: runtime configuration validated")) validated++;
    else if (strstr(text, "display: runtime config missing or invalid, using profile defaults")) fallback++;
    else if (strstr(text, "display: failed to publish early display properties")) publish_errors++;
    else CHECK(strstr(text, "display: early configuration") != NULL);
    return fclose(file);
}

int property_get(const char* key, char* value, const char* default_value) {
    CHECK(strcmp(key, "ro.vendor.royd.hal_profile") == 0);
    CHECK(strcmp(default_value, "graphical") == 0);
    strcpy(value, hal_profile);
    return (int)strlen(value);
}

int property_set(const char* key, const char* value) {
    const char* keys[] = {"vendor.royd.display.width", "vendor.royd.display.height",
            "vendor.royd.display.dpi", "vendor.royd.display.fps", "vendor.royd.display.ready"};
    CHECK(properties < 5 && strcmp(key, keys[properties]) == 0);
    strcpy(published[properties], value);
    return properties++ == property_failure_at ? -1 : 0;
}

static void prepare(const char* data, size_t size) {
    CHECK(config_stream == NULL);
    memset(published, 0, sizeof(published));
    properties = validated = fallback = publish_errors = read_error = read_position = 0;
    if (!open_error) {
        config_stream = tmpfile();
        CHECK(config_stream != NULL);
        CHECK(fwrite(data, 1, size, config_stream) == size);
        rewind(config_stream);
    }
}

static void run_case(const char* data, size_t size, int valid, struct display_config expected) {
    prepare(data, size);
    CHECK(bootstrap_main() == (property_failure_at >= 0 ? 1 : 0));
    CHECK(config_stream == NULL);
    CHECK(properties == (property_failure_at >= 0 ? property_failure_at + 1 : 5));
    CHECK(validated == valid && fallback == !valid);
    CHECK(publish_errors == (property_failure_at >= 0));
    int values[] = {expected.width, expected.height, expected.dpi, expected.fps, 1};
    for (int i = 0; i < properties; ++i) {
        char text[32];
        snprintf(text, sizeof(text), "%d", values[i]);
        CHECK(strcmp(published[i], text) == 0);
    }
}

static const char* fields[] = {"ROYD_WIDTH=600", "ROYD_HEIGHT=1000", "ROYD_DPI=320", "ROYD_FPS=24"};
static const struct display_config selected = {600, 1000, 320, 24};
static const struct display_config graphical = {540, 960, 240, 30};
static const struct display_config headless = {64, 64, 72, 5};

int main(int argc, char** argv) {
    const char* canonical = "ROYD_WIDTH=600\nROYD_HEIGHT=1000\nROYD_DPI=320\nROYD_FPS=24\n"
            "ROYD_RESOURCE_PROFILE=low-memory\n";
    run_case(canonical, strlen(canonical), 1, selected);
    // Every ordering, both line endings, both profile modes and four-field inputs.
    for (int a = 0; a < 4; ++a) for (int b = 0; b < 4; ++b)
    for (int c = 0; c < 4; ++c) for (int d = 0; d < 4; ++d) {
        if (a == b || a == c || a == d || b == c || b == d || c == d) continue;
        for (int mode = 0; mode < 3; ++mode) for (int crlf = 0; crlf < 2; ++crlf) {
            const char* eol = crlf ? "\r\n" : "\n";
            char data[256];
            snprintf(data, sizeof(data), "%s%s%s%s%s%s%s%s%s%s", fields[a], eol,
                    mode == 1 ? "ROYD_RESOURCE_PROFILE=low-memory" : mode == 2
                    ? "ROYD_RESOURCE_PROFILE=performance" : "", eol,
                    fields[b], eol, fields[c], eol, fields[d], eol);
            run_case(data, strlen(data), 1, selected);
            data[strlen(data) - (crlf ? 2 : 1)] = '\0';
            run_case(data, strlen(data), 1, selected);
        }
    }
    for (int missing = 0; missing < 4; ++missing) {
        char data[256] = "";
        for (int i = 0; i < 4; ++i) if (i != missing) {
            strcat(data, fields[i]); strcat(data, "\n");
        }
        run_case(data, strlen(data), 0, graphical);
    }
    const char* bad_values[] = {"", "0", "-1", "+1", " 1", "1 ", "1x", "1.5",
            "999999999999999999999999999999999", "1\rjunk"};
    for (int field = 0; field < 4; ++field) {
        for (size_t v = 0; v < sizeof(bad_values) / sizeof(bad_values[0]) + 1; ++v) {
            char data[512] = "";
            for (int i = 0; i < 4; ++i) {
                if (i == field) {
                    char key[32], line[128];
                    strcpy(key, fields[i]); *strchr(key, '=') = '\0';
                    snprintf(line, sizeof(line), "%s=%s\n", key,
                            v == sizeof(bad_values) / sizeof(bad_values[0])
                            ? (field < 2 ? "16385" : field == 2 ? "2001" : "1001") : bad_values[v]);
                    strcat(data, line);
                } else { strcat(data, fields[i]); strcat(data, "\n"); }
            }
            run_case(data, strlen(data), 0, graphical);
        }
        char duplicate[512];
        snprintf(duplicate, sizeof(duplicate), "%s%s\n", canonical, fields[field]);
        run_case(duplicate, strlen(duplicate), 0, graphical);
    }
    const char* suffixes[] = {"UNKNOWN=1\n", "not-an-assignment\n", "ROYD_RESOURCE_PROFILE=bogus\n",
            "ROYD_RESOURCE_PROFILE=\n", "ROYD_RESOURCE_PROFILE=performance\n"};
    for (size_t i = 0; i < sizeof(suffixes) / sizeof(suffixes[0]); ++i) {
        char data[512];
        snprintf(data, sizeof(data), "%s%s", canonical, suffixes[i]);
        run_case(data, strlen(data), 0, graphical);
    }
    run_case("", 0, 0, graphical);
    run_case("\n\r\n", 3, 0, graphical);
    const char* duplicate_missing = "ROYD_WIDTH=600\nROYD_WIDTH=601\nROYD_DPI=320\nROYD_FPS=24\n";
    run_case(duplicate_missing, strlen(duplicate_missing), 0, graphical);
    const char* limits = "\nROYD_WIDTH=16384\nROYD_HEIGHT=1\nROYD_DPI=2000\nROYD_FPS=1000\n";
    run_case(limits, strlen(limits), 1, (struct display_config){16384, 1, 2000, 1000});
    char binary[] = "ROYD_WIDTH=600\0junk\nROYD_HEIGHT=1000\nROYD_DPI=320\nROYD_FPS=24\n";
    run_case(binary, sizeof(binary) - 1, 0, graphical);
    char long_line[512];
    for (int length = 126; length <= 128; ++length) {
        strcpy(long_line, "ROYD_WIDTH=");
        memset(long_line + 11, '0', (size_t)length - 14);
        strcpy(long_line + length - 3, "600\nROYD_HEIGHT=1000\nROYD_DPI=320\nROYD_FPS=24\n");
        run_case(long_line, strlen(long_line), length <= 127, length <= 127 ? selected : graphical);
    }
    for (int error = 0; error < 3; ++error) {
        read_failure_at = error == 0 ? 0 : error == 1 ? 20 : (int)strlen(canonical);
        run_case(canonical, strlen(canonical), 0, graphical);
    }
    read_failure_at = -1;
    close_error = 1;
    run_case(canonical, strlen(canonical), 0, graphical);
    close_error = 0;
    for (int error = 0; error < 2; ++error) {
        open_error = error == 0 ? ENOENT : EACCES;
        run_case(canonical, strlen(canonical), 0, graphical);
    }
    open_error = 0;
    hal_profile = "headless";
    run_case("ROYD_WIDTH=600\nUNKNOWN=1\n", 25, 0, headless);
    run_case(canonical, strlen(canonical), 1, selected);
    hal_profile = "graphical";
    for (int i = 0; i < 5; ++i) {
        property_failure_at = i;
        run_case(canonical, strlen(canonical), 1, selected);
    }
    property_failure_at = -1;
    struct display_config sentinel = {7, 8, 9, 10};
    prepare("ROYD_WIDTH=600\nUNKNOWN=1\n", 25);
    CHECK(load_config(&sentinel) != 0);
    CHECK(sentinel.width == 7 && sentinel.height == 8 && sentinel.dpi == 9 && sentinel.fps == 10);
    if (argc == 2) {
        FILE* file = fopen(argv[1], "r");
        char data[512];
        CHECK(file != NULL);
        size_t size = fread(data, 1, sizeof(data), file);
        CHECK(!ferror(file) && feof(file));
        CHECK(fclose(file) == 0);
        run_case(data, size, 1, selected);
    }
    puts("Executable display-bootstrap parsing and publication contract passed");
    return 0;
}
