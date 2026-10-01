/* prospero-lld.exe - ld.lld forwarder for the upstream clang PS5 driver.
 * clang -target x86_64-sie-ps5 hardcodes the linker name "prospero-lld" and
 * emits args meant for Sony's lld (-m elf_x86_64_fbsd, --default-script, -pie).
 * This forwards to stock ld.lld with the flags adjusted for payload .so/.elf
 * output: GNU elf_x86_64, no pie when --shared/-r, --default-script dropped
 * (an explicit -T wins), -z max-page-size=0x4000 and -mllvm -emulated-tls kept.
 * No libc: built -nostdlib against kernel32.dll directly.
 */
typedef unsigned long DWORD;
typedef unsigned long long U64;
typedef int BOOL;
typedef void *HANDLE;
typedef char *LPSTR;
typedef const char *LPCSTR;
typedef unsigned short WORD;
typedef unsigned char BYTE;

typedef struct _PROCESS_INFORMATION {
    HANDLE hProcess, hThread;
    DWORD dwProcessId, dwThreadId;
} PROCESS_INFORMATION;

typedef struct _STARTUPINFOA_PLAIN {
    DWORD cb;
    BYTE pad[100]; /* sizeof(STARTUPINFOA) == 104, handles land past cb */
    HANDLE reserved[2];
} STARTUPINFOA_PLAIN;

__declspec(dllimport) LPSTR __stdcall GetCommandLineA(void);
__declspec(dllimport) BOOL __stdcall CreateProcessA(LPCSTR, LPSTR, void *, void *,
                                                   BOOL, DWORD, void *, LPCSTR,
                                                   void *, PROCESS_INFORMATION *);
__declspec(dllimport) DWORD __stdcall WaitForSingleObject(HANDLE, DWORD);
__declspec(dllimport) BOOL __stdcall GetExitCodeProcess(HANDLE, DWORD *);
__declspec(dllimport) void __stdcall ExitProcess(DWORD);
__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD);
__declspec(dllimport) BOOL __stdcall WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);

void __chkstk(void) {} /* no libc stack probing needed here */
static int xstrlen(const char *s) { int n = 0; while (s[n]) ++n; return n; }
static int xstreq(const char *a, const char *b) {
    while (*a && *a == *b) ++a, ++b;
    return *a == *b;
}
static int xstarts(const char *a, const char *b) {
    while (*b && *a == *b) ++a, ++b;
    return *b == 0;
}
static void put(LPCSTR s) {
    DWORD n = 0;
    WriteFile(GetStdHandle((DWORD)-11), s, (DWORD)xstrlen(s), &n, 0);
}

/* skip argv[0] in a command line: honour double quotes */
static char *skip_argv0(char *p) {
    while (*p == ' ' || *p == '\t') ++p;
    if (*p == '"') {
        ++p;
        while (*p && *p != '"') ++p;
        if (*p == '"') ++p;
    } else {
        while (*p && *p != ' ' && *p != '\t') ++p;
    }
    return p;
}

/* append one token, quoting it if it contains spaces or quotes are needed */
static char *app(char *o, const char *t) {
    int needq = 0;
    for (const char *s = t; *s; ++s)
        if (*s == ' ' || *s == '\t' || *s == '"') { needq = 1; break; }
    if (needq) *o++ = '"';
    while (*t) *o++ = *t++;
    if (needq) *o++ = '"';
    return o;
}

void mainCRTStartup(void) {
    static char cmd[256 * 1024];
    char *args = skip_argv0(GetCommandLineA());
    char *o = cmd;
    /* ld.lld <ps5 defaults> <filtered args> */
    o = app(o, "ld.lld.exe");
    const char *prefix[] = { "-m", "elf_x86_64", "--eh-frame-hdr",
                             "-z", "max-page-size=0x4000",
                             "-mllvm", "-emulated-tls" };
    for (unsigned i = 0; i < sizeof(prefix) / sizeof(prefix[0]); ++i) {
        *o++ = ' ';
        o = app(o, prefix[i]);
    }
    int want_pie = 1;
    for (char *scan = args; *scan; ++scan)
        if (xstarts(scan, "--shared") || xstarts(scan, "-shared") ||
            (scan[0] == '-' && scan[1] == 'r' && (scan[2] == ' ' || scan[2] == 0))) {
            want_pie = 0;
            break;
        }
    if (want_pie) {
        /* no pie here: cores are always -shared; keep for exe links via -pie below */
    }
    int drop_next = 0;
    while (*args) {
        while (*args == ' ' || *args == '\t') ++args;
        if (!*args) break;
        char tok[4096];
        int n = 0, quoted = 0;
        if (*args == '"') { quoted = 1; ++args; }
        while (*args && (quoted ? *args != '"' : (*args != ' ' && *args != '\t')))
            if (n < (int)sizeof(tok) - 1) tok[n++] = *args++;
        if (quoted && *args == '"') ++args;
        tok[n] = 0;

        if (drop_next) { drop_next = 0; continue; }
        if (xstreq(tok, "--default-script")) { drop_next = 1; continue; }
        if (xstreq(tok, "-pie") || xstreq(tok, "--pie")) continue;
        if (xstreq(tok, "-m")) { /* keep */ }
        *o++ = ' ';
        o = app(o, tok);
    }
    *o = 0;

    PROCESS_INFORMATION pi;
    static STARTUPINFOA_PLAIN si;
    si.cb = 104; /* sizeof STARTUPINFOA */
    DWORD exit_code = 1;
    if (CreateProcessA(0, cmd, 0, 0, 1, 0, 0, 0, &si, &pi)) {
        WaitForSingleObject(pi.hProcess, 0xFFFFFFFF);
        GetExitCodeProcess(pi.hProcess, &exit_code);
    } else {
        put("prospero-lld: could not start ld.lld\n");
    }
    ExitProcess(exit_code);
}
