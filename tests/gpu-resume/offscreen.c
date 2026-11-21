/* SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <gbm.h>
#include <dirent.h>
#include <fcntl.h>
#include <glob.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

enum { W = 64, H = 32, CTX = 3, FRAMES = 4, MAX_CLIENTS = 32 };
struct usage { uint64_t id, ns, cycles; };
struct snapshot { struct usage clients[MAX_CLIENTS]; unsigned n; };

static void die(const char *message)
{
    fprintf(stderr, "GPU_CHECK_FAILED %s\n", message);
    exit(1);
}

static bool client_counters(int fd, struct usage *u)
{
    char path[64], line[256], driver[32] = "";
    bool id = false, ns = false, cycles = false;
    snprintf(path, sizeof(path), "/proc/self/fdinfo/%d", fd);
    FILE *f = fopen(path, "r");
    if (!f) return false;
    while (fgets(line, sizeof(line), f)) {
        if (sscanf(line, "drm-driver: %31s", driver) == 1) continue;
        if (sscanf(line, "drm-client-id: %" SCNu64, &u->id) == 1) id = true;
        if (sscanf(line, "drm-engine-gpu: %" SCNu64, &u->ns) == 1) ns = true;
        if (sscanf(line, "drm-cycles-gpu: %" SCNu64, &u->cycles) == 1) cycles = true;
    }
    fclose(f);
    return id && ns && cycles && !strcmp(driver, "msm");
}

static struct snapshot snapshot(dev_t render)
{
    struct snapshot s = {0};
    DIR *d = opendir("/proc/self/fd");
    if (!d) die("cannot enumerate this client's FDs");
    struct dirent *entry;
    while ((entry = readdir(d))) {
        char *end;
        long fd = strtol(entry->d_name, &end, 10);
        struct stat st;
        if (*end || fstat(fd, &st) || !S_ISCHR(st.st_mode) || st.st_rdev != render)
            continue;
        struct usage u = {0};
        if (!client_counters(fd, &u)) continue;
        unsigned i = 0;
        while (i < s.n && s.clients[i].id != u.id) i++;
        if (i == s.n) {
            if (s.n == MAX_CLIENTS) die("unexpected number of MSM DRM clients");
            s.n++;
        }
        s.clients[i] = u;
    }
    closedir(d);
    return s;
}

static void prove_retirement(dev_t render, const struct snapshot *before, unsigned cycle)
{
    for (unsigned poll = 0; poll <= 100; poll++) {
        struct snapshot after = snapshot(render);
        for (unsigned j = 0; j < after.n; j++) {
            const struct usage *u = &after.clients[j];
            struct usage old = {0};
            for (unsigned i = 0; i < before->n; i++)
                if (before->clients[i].id == u->id) old = before->clients[i];
            if (u->ns < old.ns || u->cycles < old.cycles) die("MSM client counters regressed");
            if (u->ns > old.ns || u->cycles > old.cycles) {
                printf("GPU_RETIRED context=%u drm_client=%" PRIu64 " elapsed_ns=%" PRIu64
                       " cycles=%" PRIu64 "\n", cycle, u->id, u->ns-old.ns, u->cycles-old.cycles);
                return;
            }
        }
        if (poll < 100) usleep(10000);
    }
    die("no retired GPU work on this process's MSM render node");
}

static int render_node(dev_t *rdev)
{
    glob_t g = {0};
    int found = -1;
    if (glob("/dev/dri/renderD*", GLOB_NOSORT, NULL, &g)) die("no render node");
    for (size_t i = 0; i < g.gl_pathc; i++) {
        int fd = open(g.gl_pathv[i], O_RDWR | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0) continue;
        struct usage counters;
        struct stat st;
        if (fstat(fd, &st) || !S_ISCHR(st.st_mode) || !client_counters(fd, &counters)) {
            close(fd);
            continue;
        }
        if (found >= 0) die("more than one eligible MSM render node");
        *rdev = st.st_rdev;
        found = fd;
    }
    globfree(&g);
    if (found < 0) die("no accessible MSM render node with client counters");
    return found;
}

static GLuint shader(GLenum type, const char *text)
{
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &text, NULL);
    glCompileShader(s);
    GLint ok;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512];
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        fprintf(stderr, "%s\n", log);
        die("shader compilation");
    }
    return s;
}

static GLuint program(void)
{
    const char *vs =
        "#version 300 es\n"
        "void main(){ vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);"
        "gl_Position=vec4(2.0*p-1.0,0.0,1.0); }";
    const char *fs =
        "#version 300 es\n"
        "precision highp int; uniform highp usampler2D tex; uniform uint seed;"
        "layout(location=0) out highp uvec4 result;"
        "void main(){ uvec2 p=uvec2(gl_FragCoord.xy);"
        "uvec2 q=(p+uvec2(seed*3u,seed))&uvec2(63u,31u);"
        "uvec4 t=texelFetch(tex,ivec2(q),0);"
        "result=uvec4(t.b^(p.x+seed),t.r*3u+t.g+p.y,t.a^(p.y*5u),t.g+seed*7u)&255u; }";
    GLuint vert = shader(GL_VERTEX_SHADER, vs), frag = shader(GL_FRAGMENT_SHADER, fs);
    GLuint p = glCreateProgram();
    glAttachShader(p, vert);
    glAttachShader(p, frag);
    glLinkProgram(p);
    GLint ok;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) die("program link");
    glDeleteShader(vert);
    glDeleteShader(frag);
    return p;
}

static void render_frames(unsigned cycle)
{
    uint8_t input[H][W][4], actual[H][W][4];
    for (unsigned y = 0; y < H; y++)
        for (unsigned x = 0; x < W; x++)
            for (unsigned c = 0; c < 4; c++)
                input[y][x][c] = x*(c*13+5) + (y^x)*(c*9+1) + cycle*31 + c*71;
    GLuint textures[2], fbo, vao, p = program();
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    glGenTextures(2, textures);
    glBindTexture(GL_TEXTURE_2D, textures[1]);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8UI, W, H);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, textures[1], 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) die("integer framebuffer");
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, textures[0]);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8UI, W, H);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H, GL_RGBA_INTEGER, GL_UNSIGNED_BYTE, input);
    glUseProgram(p);
    glUniform1i(glGetUniformLocation(p, "tex"), 0);
    GLint seed_loc = glGetUniformLocation(p, "seed");
    if (seed_loc < 0) die("shader seed missing");
    glViewport(0, 0, W, H);
    for (unsigned frame = 0; frame < FRAMES; frame++) {
        unsigned seed = cycle*FRAMES + frame + 1;
        glUniform1ui(seed_loc, seed);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glReadPixels(0, 0, W, H, GL_RGBA_INTEGER, GL_UNSIGNED_BYTE, actual);
        if (glGetError() != GL_NO_ERROR) die("integer draw/readback");
        for (unsigned y = 0; y < H; y++) {
            for (unsigned x = 0; x < W; x++) {
                const uint8_t *t = input[(y+seed)%H][(x+3*seed)%W];
                uint8_t expected[] = { t[2]^(x+seed), t[0]*3+t[1]+y, t[3]^(y*5), t[1]+7*seed };
                if (memcmp(actual[y][x], expected, 4)) die("RGBA mismatch");
            }
        }
    }
    glFinish();
    glDeleteProgram(p);
    glDeleteVertexArrays(1, &vao);
    glDeleteFramebuffers(1, &fbo);
    glDeleteTextures(2, textures);
}

int main(int argc, char **argv)
{
    bool soft = argc == 2 && !strcmp(argv[1], "--software-control");
    if (argc != 1 && !soft) die("usage: gpu-offscreen [--software-control]");
    setvbuf(stdout, NULL, _IOLBF, 0);
    dev_t rdev = 0;
    int fd = -1;
    struct gbm_device *gbm = NULL;
    EGLenum platform = EGL_PLATFORM_SURFACELESS_MESA;
    if (!soft) {
        fd = render_node(&rdev);
        gbm = gbm_create_device(fd);
        if (!gbm) die("GBM render device");
        platform = EGL_PLATFORM_GBM_KHR;
    }
    EGLDisplay d = eglGetPlatformDisplay(platform, gbm, NULL);
    if (d == EGL_NO_DISPLAY || !eglInitialize(d, NULL, NULL) || !eglBindAPI(EGL_OPENGL_ES_API))
        die("headless EGL initialization");
    const EGLint conf[] = { EGL_SURFACE_TYPE, 0, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE };
    EGLConfig config;
    EGLint count;
    if (!eglChooseConfig(d, conf, &config, 1, &count) || count != 1) die("ES3 configuration");
    const EGLint attrs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    for (unsigned c = 0; c < CTX; c++) {
        EGLContext context = eglCreateContext(d, config, EGL_NO_CONTEXT, attrs);
        if (context == EGL_NO_CONTEXT || !eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, context))
            die("surfaceless ES3 context");
        const char *renderer = (const char *)glGetString(GL_RENDERER);
        if (!renderer) die("missing GL renderer");
        if (!c) printf("GPU_RENDERER mode=%s renderer=%s\n", soft ? "software-control" : "hardware", renderer);
        if (soft ? !strstr(renderer, "llvmpipe") : strcmp(renderer, "FD730")) die("renderer identity mismatch");
        struct snapshot before = {0};
        if (!soft) before = snapshot(rdev);
        render_frames(c);
        if (!soft) prove_retirement(rdev, &before, c);
        if (!eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT) || !eglDestroyContext(d, context))
            die("context release");
    }
    if (!eglTerminate(d) || !eglReleaseThread()) die("EGL release");
    if (gbm) gbm_device_destroy(gbm);
    if (fd >= 0) close(fd);
    printf("%s contexts=%d frames=%d pixels=%d\n",
           soft ? "GPU_SOFTWARE_CONTROL_PASS" : "GPU_HARDWARE_PASS", CTX, CTX*FRAMES, W*H*CTX*FRAMES);
    return 0;
}
