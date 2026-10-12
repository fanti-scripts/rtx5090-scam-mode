// dxgi_proxy.cpp - DXGI proxy that rewrites NVIDIA adapter identity.
//
// Strategy: we do NOT wrap COM objects (that would require proxying 7 levels of
// IDXGIFactory inheritance). Instead we patch the *vtable* of IDXGIAdapter /
// IDXGIAdapter1 in-place. The vtable lives in read-only .rdata of dxgi_orig.dll,
// but it is shared per-process by every adapter object of that interface, so
// patching it once affects the whole process - Task Manager, GPU-Z, every DXGI
// consumer - while we keep passing the *real* factory object back to callers.
//
// Everything else is a plain PE export forwarder (see dxgi_proxy.def).

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <dxgi1_6.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdio.h>

// ------------------------------------------------------------------ debug ----

static void Dbg(const char* fmt, ...) {
    char buf[600];
    va_list ap; va_start(ap, fmt);
    int n = _vsnprintf_s(buf, sizeof(buf), _TRUNCATE, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    OutputDebugStringA(buf);

    wchar_t dir[MAX_PATH];
    if (!GetTempPathW(MAX_PATH, dir)) return;
    wcscat_s(dir, MAX_PATH, L"dxgi_proxy.log");
    HANDLE h = CreateFileW(dir, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    DWORD written;
    WriteFile(h, buf, (DWORD)strlen(buf), &written, NULL);
    WriteFile(h, "\n", 1, &written, NULL);
    CloseHandle(h);
}

// ---------------------------------------------------------------- config ----

static const UINT   FAKE_VENDOR = 0x10DE;   // NVIDIA
static const SIZE_T DEFAULT_VRAM = (SIZE_T)24 * 1024ull * 1024 * 1024;
static const WCHAR  DEFAULT_NAME[] = L"NVIDIA GeForce RTX 5090";

static WCHAR g_fakeName[128] = L"";
static SIZE_T g_fakeVram    = 0;

static void LoadConfig() {
    if (g_fakeVram) return;
    wcscpy_s(g_fakeName, 128, DEFAULT_NAME);
    g_fakeVram = DEFAULT_VRAM;

    // optional overrides, no recompile needed
    wchar_t buf[128];
    DWORD n = GetEnvironmentVariableW(L"FAKE_GPU_NAME", buf, 128);
    if (n > 0 && n < 128) wcscpy_s(g_fakeName, buf);

    n = GetEnvironmentVariableW(L"FAKE_VRAM_MB", buf, 128);
    if (n > 0) {
        long long mb = _wtoi64(buf);
        if (mb > 0) g_fakeVram = (SIZE_T)mb * 1024 * 1024;
    }
}

// ------------------------------------------------------------------ real ----

typedef HRESULT (WINAPI *PFN_CreateDXGIFactory )(REFIID, void**);
typedef HRESULT (WINAPI *PFN_CreateDXGIFactory1)(REFIID, void**);
typedef HRESULT (WINAPI *PFN_CreateDXGIFactory2)(REFIID, REFIID, void**);

static HMODULE g_hModule = NULL;
static HMODULE g_real = NULL;
static PFN_CreateDXGIFactory  Real_CreateDXGIFactory  = NULL;
static PFN_CreateDXGIFactory1 Real_CreateDXGIFactory1 = NULL;
static PFN_CreateDXGIFactory2 Real_CreateDXGIFactory2 = NULL;

static void EnsureReal() {
    if (g_real) return;

    // 1) production layout: C:\Windows\System32\dxgi_orig.dll
    wchar_t sys[MAX_PATH];
    if (GetSystemDirectoryW(sys, MAX_PATH)) {
        wchar_t p[MAX_PATH];
        wcscpy_s(p, MAX_PATH, sys);
        wcscat_s(p, MAX_PATH, L"\\dxgi_orig.dll");
        g_real = LoadLibraryW(p);
    }

    // 2) dev/test layout: dxgi_orig.dll sitting next to this proxy
    if (!g_real) {
        wchar_t self[MAX_PATH];
        if (GetModuleFileNameW(g_hModule, self, MAX_PATH)) {
            wchar_t* slash = wcsrchr(self, L'\\');
            if (slash) {
                *slash = 0;
                wcscat_s(self, MAX_PATH, L"\\dxgi_orig.dll");
                g_real = LoadLibraryW(self);
            }
        }
    }

    if (!g_real) return;
    Real_CreateDXGIFactory  = (PFN_CreateDXGIFactory )GetProcAddress(g_real, "CreateDXGIFactory");
    Real_CreateDXGIFactory1 = (PFN_CreateDXGIFactory1)GetProcAddress(g_real, "CreateDXGIFactory1");
    Real_CreateDXGIFactory2 = (PFN_CreateDXGIFactory2)GetProcAddress(g_real, "CreateDXGIFactory2");
}

// ----------------------------------------------------------------- hooks ----
// IDXGIAdapter vtable:  0 QI | 1 AddRef | 2 Release | 3 EnumOutputs | 4 GetDesc | 5 CheckInterfaceSupport
// IDXGIAdapter1 vtable: ... 6 GetDesc1

typedef HRESULT (STDMETHODCALLTYPE *PFN_GetDesc )(void*, DXGI_ADAPTER_DESC*);
typedef HRESULT (STDMETHODCALLTYPE *PFN_GetDesc1)(void*, DXGI_ADAPTER_DESC1*);

static PFN_GetDesc  Orig_GetDesc_A0;   // IDXGIAdapter::GetDesc
static PFN_GetDesc  Orig_GetDesc_A1;   // IDXGIAdapter1::GetDesc
static PFN_GetDesc1 Orig_GetDesc1_A1;  // IDXGIAdapter1::GetDesc1

static void FixDesc(DXGI_ADAPTER_DESC* d) {
    if (d->VendorId != FAKE_VENDOR) return;      // touch NVIDIA only
    wcsncpy_s(d->Description, 128, g_fakeName, _TRUNCATE);
    d->DedicatedVideoMemory = g_fakeVram;
}

static void FixDesc1(DXGI_ADAPTER_DESC1* d) {
    if (d->VendorId != FAKE_VENDOR) return;
    wcsncpy_s(d->Description, 128, g_fakeName, _TRUNCATE);
    d->DedicatedVideoMemory = g_fakeVram;
}

static HRESULT STDMETHODCALLTYPE Hook_GetDesc_A0(void* self, DXGI_ADAPTER_DESC* d) {
    HRESULT hr = Orig_GetDesc_A0(self, d);
    if (SUCCEEDED(hr)) FixDesc(d);
    return hr;
}
static HRESULT STDMETHODCALLTYPE Hook_GetDesc_A1(void* self, DXGI_ADAPTER_DESC* d) {
    HRESULT hr = Orig_GetDesc_A1(self, d);
    if (SUCCEEDED(hr)) FixDesc(d);
    return hr;
}
static volatile LONG g_entered = 0, g_returned = 0;

static HRESULT STDMETHODCALLTYPE Hook_GetDesc1_A1(void* self, DXGI_ADAPTER_DESC1* d) {
    if (InterlockedCompareExchange(&g_entered, 1, 0) == 0)
        Dbg("[%lu] hook ENTER orig=%p self=%p d=%p", GetCurrentThreadId(),
            (void*)Orig_GetDesc1_A1, self, d);
    HRESULT hr = Orig_GetDesc1_A1(self, d);
    if (InterlockedCompareExchange(&g_returned, 1, 0) == 0)
        Dbg("[%lu] hook RETURN hr=0x%08lX", GetCurrentThreadId(), (unsigned long)hr);
    if (SUCCEEDED(hr)) FixDesc1(d);
    return hr;
}

// ------------------------------------------------------------- vtable --------

static void SwapSlot(void** vt, int slot, void* newFn, void** savedOld) {
    if (!vt || !vt[slot]) return;
    // Already patched by us - bail out BEFORE touching savedOld. Several
    // adapters in a process can share one vtable, and overwriting the saved
    // original with our own hook is what turns this into infinite recursion.
    if (vt[slot] == newFn) return;
    if (*savedOld == NULL) *savedOld = vt[slot];

    DWORD oldProt = 0;
    const SIZE_T bytes = (SIZE_T)(sizeof(void*) * (size_t)(slot + 1));
    if (!VirtualProtect((LPVOID)vt, bytes, (DWORD)PAGE_READWRITE, (DWORD*)&oldProt))
        return;
    vt[slot] = newFn;
    FlushInstructionCache(GetCurrentProcess(), (LPCVOID)vt, bytes);
    VirtualProtect((LPVOID)vt, bytes, (DWORD)oldProt, (DWORD*)&oldProt);
}

static void PatchAdapter0VTable(void** vt) {
    SwapSlot(vt, 4, (void*)Hook_GetDesc_A0, (void**)&Orig_GetDesc_A0);
}
static void PatchAdapter1VTable(void** vt) {
    SwapSlot(vt, 4, (void*)Hook_GetDesc_A1, (void**)&Orig_GetDesc_A1);
    SwapSlot(vt, 6, (void*)Hook_GetDesc1_A1, (void**)&Orig_GetDesc1_A1);
}

static volatile LONG g_patched = 0;

static void DoPatch() {
    if (InterlockedExchange(&g_patched, 1) != 0) return;

    LoadConfig();
    EnsureReal();
    Dbg("[%lu] DoPatch: g_real=%p CreateDXGIFactory1=%p",
        GetCurrentThreadId(), (void*)g_real, (void*)Real_CreateDXGIFactory1);

    if (!Real_CreateDXGIFactory1) { InterlockedExchange(&g_patched, 0); return; }

    IDXGIFactory1* f = NULL;
    HRESULT hr = Real_CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void**)&f);
    Dbg("[%lu] probe CreateDXGIFactory1 -> 0x%08lX factory=%p",
        GetCurrentThreadId(), (unsigned long)hr, (void*)f);
    if (FAILED(hr) || !f) { InterlockedExchange(&g_patched, 0); return; }

    for (UINT i = 0;; ++i) {
        IDXGIAdapter1* a1 = NULL;
        if (FAILED(f->EnumAdapters1(i, &a1)) || !a1) break;

        void** vt1 = *(void***)a1;
        IDXGIAdapter* a0 = NULL;
        void** vt0 = NULL;
        if (SUCCEEDED(a1->QueryInterface(__uuidof(IDXGIAdapter), (void**)&a0)) && a0)
            vt0 = *(void***)a0;

        // GetDesc sits at slot 4 in both interfaces with an identical
        // signature, so when the object hands out one shared vtable patching
        // it once is enough - patching twice would swap our hooks over each
        // other's "original" pointer.
        if (vt0 && vt0 != vt1) {
            PatchAdapter1VTable(vt1);
            PatchAdapter0VTable(vt0);
        } else {
            PatchAdapter1VTable(vt1);
        }

        DXGI_ADAPTER_DESC1 d1; ZeroMemory(&d1, sizeof(d1));
        a1->GetDesc1(&d1);
        char nm[64] = { 0 };
        for (int k = 0; k < 63 && d1.Description[k]; ++k)
            nm[k] = (d1.Description[k] < 128) ? (char)d1.Description[k] : '?';
        Dbg("[%lu] ad[%u] vt1=%p vt0=%p GetDesc1 now = \"%s\" vram=%.1f GB",
            GetCurrentThreadId(), i, (void*)vt1, (void*)vt0, nm,
            d1.DedicatedVideoMemory / 1073741824.0);

        if (a0) a0->Release();
        a1->Release();
    }
    f->Release();
}

static DWORD WINAPI PatchThread(LPVOID) { DoPatch(); return 0; }

// ---------------------------------------------------- generic forwarders ----
//
// MSVC's linker does not support PE export forwarders ("x = dll.x"), so the
// remaining 17 exports are implemented here. On x64 the first four integer
// arguments always arrive in RCX/RDX/R8/R9 and the caller owns the shadow
// space, so __cdecl == __stdcall and pushing all four slots through is correct
// regardless of how many arguments the real function actually declares.

typedef void (__stdcall *PFN_any)(void*, void*, void*, void*);

enum {
    F_ApplyCompatResolutionQuirking, F_CompatString, F_CompatValue,
    F_DXGIDumpJournal, F_PIXBeginCapture, F_PIXEndCapture, F_PIXGetCaptureState,
    F_SetAppCompatStringPointer, F_UpdateHMDEmulationStatus,
    F_DXGID3D10CreateDevice, F_DXGID3D10CreateLayeredDevice,
    F_DXGID3D10GetLayeredDeviceSize, F_DXGID3D10RegisterLayers,
    F_DXGIDeclareAdapterRemovalSupport, F_DXGIDisableVBlankVirtualization,
    F_DXGIGetDebugInterface1, F_DXGIReportAdapterConfiguration,
    F_COUNT
};

static PFN_any g_fwd[F_COUNT] = { 0 };

static const char* const g_fwdNames[F_COUNT] = {
    "ApplyCompatResolutionQuirking", "CompatString", "CompatValue",
    "DXGIDumpJournal", "PIXBeginCapture", "PIXEndCapture", "PIXGetCaptureState",
    "SetAppCompatStringPointer", "UpdateHMDEmulationStatus",
    "DXGID3D10CreateDevice", "DXGID3D10CreateLayeredDevice",
    "DXGID3D10GetLayeredDeviceSize", "DXGID3D10RegisterLayers",
    "DXGIDeclareAdapterRemovalSupport", "DXGIDisableVBlankVirtualization",
    "DXGIGetDebugInterface1", "DXGIReportAdapterConfiguration"
};

static void InitFwdTable() {
    EnsureReal();
    if (!g_real) return;
    for (int i = 0; i < F_COUNT; ++i)
        g_fwd[i] = (PFN_any)GetProcAddress(g_real, g_fwdNames[i]);
}

#define DEF_FWD(fn) \
    extern "C" void __stdcall Fwd_##fn(void* a, void* b, void* c, void* d) { \
        if (g_fwd[F_##fn]) g_fwd[F_##fn](a, b, c, d); \
    }

DEF_FWD(ApplyCompatResolutionQuirking)
DEF_FWD(CompatString)
DEF_FWD(CompatValue)
DEF_FWD(DXGIDumpJournal)
DEF_FWD(PIXBeginCapture)
DEF_FWD(PIXEndCapture)
DEF_FWD(PIXGetCaptureState)
DEF_FWD(SetAppCompatStringPointer)
DEF_FWD(UpdateHMDEmulationStatus)
DEF_FWD(DXGID3D10CreateDevice)
DEF_FWD(DXGID3D10CreateLayeredDevice)
DEF_FWD(DXGID3D10GetLayeredDeviceSize)
DEF_FWD(DXGID3D10RegisterLayers)
DEF_FWD(DXGIDeclareAdapterRemovalSupport)
DEF_FWD(DXGIDisableVBlankVirtualization)
DEF_FWD(DXGIGetDebugInterface1)
DEF_FWD(DXGIReportAdapterConfiguration)

// --------------------------------------------------------------- exports ----

// Names differ from the public ones because <dxgi1_3.h> already declares
// CreateDXGIFactory2. The .def file maps these to the real export names.
extern "C" HRESULT WINAPI Proxy_CreateDXGIFactory (REFIID riid, void** pp) {
    DoPatch(); EnsureReal();
    if (!Real_CreateDXGIFactory) return E_FAIL;
    return Real_CreateDXGIFactory(riid, pp);
}
extern "C" HRESULT WINAPI Proxy_CreateDXGIFactory1(REFIID riid, void** pp) {
    DoPatch(); EnsureReal();
    if (!Real_CreateDXGIFactory1) return E_FAIL;
    return Real_CreateDXGIFactory1(riid, pp);
}
extern "C" HRESULT WINAPI Proxy_CreateDXGIFactory2(REFIID riid, REFIID riid2, void** pp) {
    DoPatch(); EnsureReal();
    if (!Real_CreateDXGIFactory2) return E_FAIL;
    return Real_CreateDXGIFactory2(riid, riid2, pp);
}

BOOL APIENTRY DllMain(HMODULE h, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_hModule = h;
        DisableThreadLibraryCalls(h);
        // LoadLibrary is legal from DllMain, and doing it here means every
        // forwarder is wired up before any caller can reach one. Doing it
        // lazily from inside a forwarder could deadlock on the loader lock.
        InitFwdTable();
        CreateThread(NULL, 0, PatchThread, NULL, 0, NULL);
    }
    return TRUE;
}