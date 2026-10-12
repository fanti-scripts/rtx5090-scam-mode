// test_dxgi.cpp - loads a dxgi proxy by path and prints what it reports.
#include <windows.h>
#include <dxgi1_6.h>
#include <stdio.h>

typedef HRESULT (WINAPI *PFN_CreateDXGIFactory1)(REFIID, void**);
typedef HRESULT (STDMETHODCALLTYPE *PFN_GetDesc)(void*, DXGI_ADAPTER_DESC*);
typedef HRESULT (STDMETHODCALLTYPE *PFN_GetDesc1)(void*, DXGI_ADAPTER_DESC1*);

static void print_w(const WCHAR* w, int n) {
    for (int i = 0; i < n && w[i]; ++i) putchar(w[i] < 128 ? w[i] : '?');
}

static void dump_veh(const char* tag, EXCEPTION_POINTERS* ep) {
    CONTEXT* c = ep->ContextRecord;
    char buf[600];
    int n = _snprintf_s(buf, sizeof(buf), _TRUNCATE,
        "%s code=0x%08lX fault=%p RIP=%llX RSP=%llX RCX=%llX RDX=%llX R8=%llX R9=%llX\n",
        tag, ep->ExceptionRecord->ExceptionCode,
        (void*)ep->ExceptionRecord->ExceptionInformation[1],
        (unsigned long long)c->Rip, (unsigned long long)c->Rsp,
        (unsigned long long)c->Rcx, (unsigned long long)c->Rdx,
        (unsigned long long)c->R8,  (unsigned long long)c->R9);
    if (n <= 0) return;
    HANDLE h = CreateFileW(L"C:\\Users\\skamf\\AppData\\Local\\Temp\\opencode\\veh.log",
                           FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    DWORD w;
    WriteFile(h, buf, (DWORD)n, &w, NULL);
    CloseHandle(h);
}

static LONG CALLBACK Veh(EXCEPTION_POINTERS* ep) {
    DWORD code = ep->ExceptionRecord->ExceptionCode;
    if (code == EXCEPTION_ACCESS_VIOLATION || code == EXCEPTION_STACK_OVERFLOW ||
        code == EXCEPTION_ILLEGAL_INSTRUCTION)
        dump_veh("[VEH]", ep);
    return EXCEPTION_CONTINUE_SEARCH;
}

int wmain(int argc, wchar_t** argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    AddVectoredExceptionHandler(1, Veh);
    if (argc < 2) { printf("usage: test_dxgi <path-to-dxgi.dll>\n"); return 2; }

    HMODULE h = LoadLibraryExW(argv[1], NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!h) { printf("LoadLibraryEx failed: %lu\n", GetLastError()); return 1; }

    PFN_CreateDXGIFactory1 fn = (PFN_CreateDXGIFactory1)GetProcAddress(h, "CreateDXGIFactory1");
    if (!fn) { printf("CreateDXGIFactory1 not exported\n"); return 1; }

    IDXGIFactory1* f = NULL;
    HRESULT hr = fn(__uuidof(IDXGIFactory1), (void**)&f);
    printf("CreateDXGIFactory1 -> 0x%08lX  factory=%p\n\n", (unsigned long)hr, (void*)f);
    if (FAILED(hr) || !f) return 1;

    for (UINT i = 0;; ++i) {
        IDXGIAdapter1* a = NULL;
        HRESULT ehr = f->EnumAdapters1(i, &a);
        printf("[%u] EnumAdapters1 -> 0x%08lX  adapter=%p\n", i, (unsigned long)ehr, (void*)a);
        if (FAILED(ehr) || !a) break;

        volatile void** vt = (volatile void**)*(void***)a;
        printf("     vtable=%p  [4]=%p [6]=%p\n", (void*)vt, (void*)vt[4], (void*)vt[6]);

        // 0) sanity: is offset 0 really a standard IUnknown vtable?
        {
            static const GUID kIUnknown =
                { 0x00000000, 0x0000, 0x0000, { 0xC0,0x00,0x00,0x00,0x00,0x00,0x00,0x46 } };
            typedef HRESULT (STDMETHODCALLTYPE *PFN_QI)(void*, REFIID, void**);
            PFN_QI qi = (PFN_QI)vt[0];
            void* out = NULL;
            HRESULT h = qi(a, kIUnknown, &out);
            printf("     step 0: manual QI(IUnknown) -> hr=0x%08lX out=%p  (this=%p, factory=%p)%s\n",
                   (unsigned long)h, out, (void*)a, (void*)f,
                   (out == (void*)a) ? "  <-- layout OK" : "  <-- LAYOUT WRONG");
        }

        // 1) straight through the compiler-generated call
        DXGI_ADAPTER_DESC1 d1; ZeroMemory(&d1, sizeof(d1));
        printf("     step 1: a->GetDesc1()...\n");
        a->GetDesc1(&d1);
        printf("     step 1 done: \""); print_w(d1.Description, 128);
        printf("\" %.1f GB\n", d1.DedicatedVideoMemory / 1073741824.0);

        // 2) GetDesc through slot 4 first
        DXGI_ADAPTER_DESC d0; ZeroMemory(&d0, sizeof(d0));
        PFN_GetDesc p0 = (PFN_GetDesc)vt[4];
        printf("     step 2: slot4=%p ...\n", (void*)p0);
        HRESULT hr3 = p0(a, &d0);
        printf("     step 2 done: hr=0x%08lX \"", (unsigned long)hr3);
        print_w(d0.Description, 128);
        printf("\" %.1f GB\n", d0.DedicatedVideoMemory / 1073741824.0);

        // 3) GetDesc1 through slot 6
        DXGI_ADAPTER_DESC1 d2; ZeroMemory(&d2, sizeof(d2));
        PFN_GetDesc1 p1 = (PFN_GetDesc1)vt[6];
        printf("     step 3: slot6=%p ...\n", (void*)p1);
        HRESULT hr2 = p1(a, &d2);
        printf("     step 3 done: hr=0x%08lX \"", (unsigned long)hr2);
        print_w(d2.Description, 128);
        printf("\" %.1f GB\n", d2.DedicatedVideoMemory / 1073741824.0);

        printf("\n");
        a->Release();
    }
    f->Release();
    printf("OK\n");
    return 0;
}