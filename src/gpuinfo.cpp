// gpuinfo.cpp - prints DXGI adapter list (same API Task Manager uses)
#include <windows.h>
#include <dxgi1_6.h>
#include <stdio.h>

#pragma comment(lib, "dxgi.lib")

static void to_narrow(const WCHAR* w, char* out, size_t cap) {
    size_t i = 0;
    if (w[0] == 0x4DC0) { // D3DKMT_ENUMADAPTER2 / LUID-ish sentinel used by some overlay drivers
        snprintf(out, cap, "<special>");
        return;
    }
    for (; w[i] && i + 1 < cap; ++i) {
        if (w[i] < 128) out[i] = (char)w[i];
        else out[i] = '?';
    }
    out[i] = 0;
}

int main() {
    IDXGIFactory1* factory = NULL;
    HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    if (FAILED(hr)) { printf("CreateDXGIFactory1 failed: 0x%08lX\n", hr); return 1; }

    printf("idx  description                              vendor    VRAM        sysVRAM\n");
    printf("---------------------------------------------------------------------------\n");
    for (UINT i = 0;; ++i) {
        IDXGIAdapter1* adapter = NULL;
        hr = factory->EnumAdapters1(i, &adapter);
        if (hr == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(hr)) { printf("EnumAdapters1(%u) -> 0x%08lX\n", i, hr); break; }

        DXGI_ADAPTER_DESC1 d;
        ZeroMemory(&d, sizeof(d));
        adapter->GetDesc1(&d);

        char name[128];
        to_narrow(d.Description, name, sizeof(name));
        printf("%-4u %-40s 0x%04X   %6.1f GB   %6.1f GB\n",
               i, name, d.VendorId,
               d.DedicatedVideoMemory / 1073741824.0,
               d.SharedSystemMemory / 1073741824.0);

        void** vt = *(void***)adapter;
        printf("      vtable=%p slots:", (void*)vt);
        for (int k = 0; k < 8; ++k) printf(" [%d]=%p", k, vt[k]);
        printf("\n");
        adapter->Release();
    }
    factory->Release();
    printf("\n(exit %d)\n", GetLastError());
    return 0;
}