/* Collect first-boot prompts for Debian's passwd PAM stack on the DRM display. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <security/pam_appl.h>
#include <shadow.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sysexits.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

#define FRONTEND "/usr/libexec/y700-firstboot-drm/unl0kr"
#define CONFIG "/usr/share/y700-firstboot-drm/unl0kr.conf"

struct conversation_state {
    unsigned int prompts;
    bool retry;
    int failure;
};

static const char *account_state(void)
{
    struct spwd *account = getspnam("y700");
    if (!account || !account->sp_pwdp)
        return "unknown";
    const char *hash = account->sp_pwdp;
    if (!strcmp(hash, "!"))
        return "new";
    if (!*hash || *hash == '!' || *hash == '*')
        return "locked";
    return "active";
}

static char *ask(const char *prompt, int *failure)
{
    *failure = EX_UNAVAILABLE;
    int ends[2], status;
    if (pipe2(ends, O_CLOEXEC) < 0)
        return NULL;
    pid_t owner = getpid();
    pid_t child = fork();
    if (child == 0) {
        if (prctl(PR_SET_PDEATHSIG, SIGTERM) < 0 || getppid() != owner ||
            dup2(ends[1], STDOUT_FILENO) < 0)
            _exit(126);
        close(ends[0]);
        close(ends[1]);
        execl(FRONTEND, "unl0kr", "-n", "-C", CONFIG, "-m", prompt, (char *)NULL);
        _exit(127);
    }
    close(ends[1]);
    if (child < 0) {
        close(ends[0]);
        return NULL;
    }

    char value[PAM_MAX_RESP_SIZE + 1] = {0};
    size_t used = 0;
    bool valid = false;
    while (used < sizeof(value)) {
        ssize_t n = read(ends[0], value + used, sizeof(value) - used);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0) {
            valid = n == 0 && used != 0 && !memchr(value, '\0', used);
            break;
        }
        used += (size_t)n;
    }
    close(ends[0]);
    if (!valid)
        kill(child, SIGTERM);
    pid_t result;
    do {
        result = waitpid(child, &status, 0);
    } while (result < 0 && errno == EINTR);
    char *answer = NULL;
    if (result == child && WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        *failure = EX_DATAERR;
        if (valid)
            answer = strndup(value, used);
    }
    explicit_bzero(value, sizeof(value));
    return answer;
}

static int conversation(int count, const struct pam_message **msg,
                        struct pam_response **result, void *userdata)
{
    struct conversation_state *state = userdata;
    if (count < 1 || count > PAM_MAX_NUM_MSG)
        return PAM_CONV_ERR;
    struct pam_response *answers = calloc((size_t)count, sizeof(*answers));
    if (answers == NULL)
        return PAM_BUF_ERR;
    for (int i = 0; i < count; ++i) {
        switch (msg[i]->msg_style) {
        case PAM_TEXT_INFO:
        case PAM_ERROR_MSG:
            continue;
        case PAM_PROMPT_ECHO_OFF:
            if (state->prompts < 2) {
                const char *prompt = "Confirm the local Y700 password";
                if (state->prompts == 0)
                    prompt = state->retry ? "Try again. Set the local Y700 password"
                                          : "Set the local Y700 password";
                state->prompts++;
                answers[i].resp = ask(prompt, &state->failure);
                if (answers[i].resp && !strcmp(account_state(), "new"))
                    continue;
            }
            break;
        }
        for (int j = 0; j <= i; j++) {
            if (!answers[j].resp)
                continue;
            explicit_bzero(answers[j].resp, strlen(answers[j].resp));
            free(answers[j].resp);
        }
        free(answers);
        return PAM_CONV_ERR;
    }
    *result = answers;
    return PAM_SUCCESS;
}

int main(int argc, char **argv)
{
    if (geteuid() != 0)
        return EX_NOPERM;
    if (argc == 2 && !strcmp(argv[1], "--state")) {
        puts(account_state());
        return EXIT_SUCCESS;
    }
    bool retry = argc == 2 && !strcmp(argv[1], "--retry");
    if (argc != 1 && !retry)
        return EX_USAGE;
    struct rlimit no_core = {0, 0};
    if (setrlimit(RLIMIT_CORE, &no_core) < 0 ||
        prctl(PR_SET_DUMPABLE, 0) < 0 || access("/etc/y700/user-configured", F_OK) == 0)
        return EX_NOPERM;
    if (strcmp(account_state(), "new"))
        return EX_NOPERM;

    pam_handle_t *pamh = NULL;
    struct conversation_state state = {.retry = retry, .failure = EX_DATAERR};
    struct pam_conv conv = {conversation, &state};
    int rc = pam_start("passwd", "y700", &conv, &pamh);
    if (rc != PAM_SUCCESS)
        return EX_SOFTWARE;
    rc = pam_set_item(pamh, PAM_TTY, "tty1");
    if (rc == PAM_SUCCESS)
        rc = pam_chauthtok(pamh, 0);
    pam_end(pamh, rc);
    if (rc == PAM_SUCCESS && state.prompts == 2)
        return EXIT_SUCCESS;
    return state.failure;
}
