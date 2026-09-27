#ifndef DIRECTX_H
#define DIRECTX_H

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#define CINTERFACE
#include <d3d9.h>
#include <stdbool.h>
#include <luajit.h>
#include <lauxlib.h>

typedef struct customVertexFormat {
	FLOAT x, y, z, rhw;
	D3DCOLOR color;
} CUSTOMVERTEX;

typedef struct d3dRenderOption {
	D3DRENDERSTATETYPE option;
	DWORD value;
} d3dRenderOption_t;

extern const luaL_Reg lib_directX[];

// Recreate the device after a display or window transition leaves it lost.
HRESULT resetD3D(void);

#endif /* DIRECTX_H */
