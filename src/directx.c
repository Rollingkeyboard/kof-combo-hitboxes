#include "directx.h"

#include <stdint.h>

#define CUSTOMFVF (D3DFVF_XYZRHW | D3DFVF_DIFFUSE)
// slight overkill, but OK
#define BOX_VERTEX_BUFFER_SIZE 100
#define CHECK_RESULT(x) result = (x); \
	if (result != D3D_OK) { \
		goto done; \
	}

#define TEXTURE_METATABLE "directx.text_texture"

typedef struct textTextureHandle {
	LPDIRECT3DTEXTURE9 texture;
} TEXTUREHANDLE;

typedef struct texturedVertex {
	FLOAT x, y, z, rhw;
	D3DCOLOR color;
	FLOAT u, v;
} TEXTUREDVERTEX;

LPDIRECT3D9 d3d;
LPDIRECT3DDEVICE9 d3dDevice;
LPDIRECT3DVERTEXBUFFER9 boxBuffer;
RECT scissorRect = { .right = (LONG)1, .bottom = (LONG)1 };
D3DPRESENT_PARAMETERS presentParams;
HWND d3dWindow;

static void releaseD3DResources(void)
{
	if (boxBuffer) {
		IDirect3DVertexBuffer9_Release(boxBuffer);
		boxBuffer = NULL;
	}
	if (d3dDevice) {
		IDirect3DDevice9_Release(d3dDevice);
		d3dDevice = NULL;
	}
}

CUSTOMVERTEX templateVertex = { 0.0f, 0.0f, 1.0f, 1.0f, D3DCOLOR_RGBA(0, 0, 0, 0) };

d3dRenderOption_t renderStateOptions[] = {
	{ D3DRS_ZENABLE, FALSE },
	{ D3DRS_LIGHTING, FALSE },
	{ D3DRS_CULLMODE, D3DCULL_NONE },
	{ D3DRS_SCISSORTESTENABLE, TRUE },
	{ D3DRS_ALPHABLENDENABLE, TRUE },
	{ D3DRS_SRCBLEND, D3DBLEND_SRCALPHA },
	{ D3DRS_DESTBLEND, D3DBLEND_INVSRCALPHA },
	{ D3DRS_BLENDOP, D3DBLENDOP_ADD },
	{ D3DRS_SEPARATEALPHABLENDENABLE, TRUE },
	{ D3DRS_SRCBLENDALPHA, D3DBLEND_SRCALPHA },
	{ D3DRS_DESTBLENDALPHA, D3DBLEND_INVSRCALPHA },
	{ D3DRS_BLENDOPALPHA, D3DBLENDOP_MAX },
	{ -1, -1 } // sentinel
};

static HRESULT createD3DDevice(HWND hwnd, UINT w, UINT h)
{
	HRESULT result;
	memset(&presentParams, 0, sizeof(presentParams));
	presentParams.Windowed = TRUE;
	presentParams.SwapEffect = D3DSWAPEFFECT_COPY;
	presentParams.hDeviceWindow = hwnd,
	presentParams.BackBufferWidth = w;
	presentParams.BackBufferHeight = h;
	presentParams.BackBufferFormat = D3DFMT_A8R8G8B8;

	CHECK_RESULT(IDirect3D9_CreateDevice(
		d3d,
		D3DADAPTER_DEFAULT,
		D3DDEVTYPE_HAL,
		hwnd,
		// D3DCREATE_FPU_PRESERVE is necessary to avoid undefined behavior with LuaJIT
		D3DCREATE_HARDWARE_VERTEXPROCESSING | D3DCREATE_FPU_PRESERVE,
		&presentParams,
		&d3dDevice));

	for (int i = 0; renderStateOptions[i].option != -1 || renderStateOptions[i].value != -1; i++)
	{
		CHECK_RESULT(IDirect3DDevice9_SetRenderState(
			d3dDevice,
			renderStateOptions[i].option,
			renderStateOptions[i].value));
	}

	CHECK_RESULT(IDirect3DDevice9_CreateVertexBuffer(
		d3dDevice,
		BOX_VERTEX_BUFFER_SIZE * sizeof(CUSTOMVERTEX),
		0, // mandatory if CreateDevice used D3DCREATE_HARDWARE_VERTEXPROCESSING
		CUSTOMFVF,
		D3DPOOL_MANAGED,
		&boxBuffer,
		NULL));

	CUSTOMVERTEX *pVoid;
	CHECK_RESULT(IDirect3DVertexBuffer9_Lock(boxBuffer, 0, 0, (void**)&pVoid, 0));
	for (int i = 0; i < BOX_VERTEX_BUFFER_SIZE; i++)
	{
		memcpy(&(pVoid[i]), &templateVertex, sizeof(templateVertex));
	}
	CHECK_RESULT(IDirect3DVertexBuffer9_Unlock(boxBuffer));
	done:
	return result;
}

HRESULT setupD3D(HWND hwnd, UINT w, UINT h)
{
	d3dWindow = hwnd;
	d3d = Direct3DCreate9(D3D_SDK_VERSION);
	if (!d3d) return D3DERR_NOTAVAILABLE;
	return createD3DDevice(hwnd, w, h);
}

HRESULT resetD3D(void)
{
	if (!d3d || !d3dWindow) return D3DERR_INVALIDCALL;
	if (d3dDevice) {
		HRESULT state = IDirect3DDevice9_TestCooperativeLevel(d3dDevice);
		if (state == D3DERR_DEVICELOST) return state;
		if (state != D3DERR_DEVICENOTRESET && state != D3D_OK) return state;
	}

	// Recreating the device also recovers from driver-specific reset failures.
	releaseD3DResources();
	IDirect3D9_Release(d3d);
	d3d = Direct3DCreate9(D3D_SDK_VERSION);
	if (!d3d) return D3DERR_NOTAVAILABLE;
	return createD3DDevice(d3dWindow,
		presentParams.BackBufferWidth, presentParams.BackBufferHeight);
}

// Takes 3 arguments: HWND for which to set up Direct3D, device width/height
// Returns 1 value: HRESULT from last D3D call made (stops at first failed call)
static int l_setupD3D(lua_State *L)
{
	HWND *hwnd = (HWND*)lua_topointer(L, 1);
	UINT w = (UINT)luaL_checkint(L, 2);
	UINT h = (UINT)luaL_checkint(L, 3);
	HRESULT result = setupD3D(*hwnd, w, h);
	lua_pushinteger(L, (lua_Integer)result);
	return 1;
}

static int l_resetD3D(lua_State *L)
{
	(void)L;
	HRESULT result = resetD3D();
	lua_pushinteger(L, (lua_Integer)result);
	return 1;
}

HRESULT DXRectangleF(FLOAT leftX, FLOAT topY, FLOAT rightX, FLOAT bottomY, D3DCOLOR color)
{
	HRESULT result;
	static VOID *pVoid;
	IDirect3DVertexBuffer9_Lock(boxBuffer, 0, 0, (void**)&pVoid, 0);
	CUSTOMVERTEX vertices[] = {
		{ leftX,  topY,    1.0f, 1.0f, color },
		{ rightX, topY,    1.0f, 1.0f, color },
		{ leftX,  bottomY, 1.0f, 1.0f, color },
		{ rightX, bottomY, 1.0f, 1.0f, color }
	};
	memcpy(pVoid, vertices, sizeof(vertices));
	CHECK_RESULT(IDirect3DVertexBuffer9_Unlock(boxBuffer));
	CHECK_RESULT(IDirect3DDevice9_SetStreamSource(d3dDevice, 0, boxBuffer, 0, sizeof(CUSTOMVERTEX)));
	CHECK_RESULT(IDirect3DDevice9_DrawPrimitive(d3dDevice, D3DPT_TRIANGLESTRIP, 0, 2));
	done:
	return result;
}

// Takes 5 arguments: Left X, top Y, right X, bottom Y (all integers), fill color
// Returns 1 value: HRESULT from last D3D call made (stops at first failed call)
static int l_DXRectangle(lua_State *L)
{
	FLOAT leftX  = luaL_checknumber(L, 1), topY    = luaL_checknumber(L, 2);
	FLOAT rightX = luaL_checknumber(L, 3), bottomY = luaL_checknumber(L, 4);
	D3DCOLOR color = (D3DCOLOR)luaL_checkint(L, 5);
	HRESULT result = DXRectangleF(leftX, topY, rightX, bottomY, color);
	lua_pushinteger(L, (lua_Integer)result);
	return 1;
}

static int l_textTextureGc(lua_State *L)
{
	TEXTUREHANDLE *handle = (TEXTUREHANDLE*)luaL_checkudata(
		L, 1, TEXTURE_METATABLE);
	if (handle->texture) {
		IDirect3DTexture9_Release(handle->texture);
		handle->texture = NULL;
	}
	return 0;
}

// Rasterize UTF-8 text with the Windows system UI font into a managed D3D texture.
static int l_createTextTexture(lua_State *L)
{
	const char *utf8 = luaL_checkstring(L, 1);
	int width = luaL_checkint(L, 2);
	int height = luaL_checkint(L, 3);
	int fontSize = luaL_optint(L, 4, 20);
	if (!d3dDevice || width <= 0 || height <= 0 || width > 2048
		|| height > 2048 || fontSize < 8 || fontSize > 96) {
		return luaL_error(L, "invalid text texture dimensions or font size");
	}

	int wideLength = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
	if (wideLength <= 0) return luaL_error(L, "invalid UTF-8 text");
	WCHAR *wideText = (WCHAR*)HeapAlloc(GetProcessHeap(), 0,
		(size_t)wideLength * sizeof(WCHAR));
	if (!wideText) return luaL_error(L, "could not allocate text buffer");
	MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wideText, wideLength);

	HDC dc = CreateCompatibleDC(NULL);
	BITMAPINFO bitmapInfo;
	memset(&bitmapInfo, 0, sizeof(bitmapInfo));
	bitmapInfo.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
	bitmapInfo.bmiHeader.biWidth = width;
	bitmapInfo.bmiHeader.biHeight = -height;
	bitmapInfo.bmiHeader.biPlanes = 1;
	bitmapInfo.bmiHeader.biBitCount = 32;
	bitmapInfo.bmiHeader.biCompression = BI_RGB;
	void *dibPixels = NULL;
	HBITMAP dib = dc ? CreateDIBSection(dc, &bitmapInfo, DIB_RGB_COLORS,
		&dibPixels, NULL, 0) : NULL;
	HGDIOBJ oldBitmap = (dc && dib) ? SelectObject(dc, dib) : NULL;
	HFONT font = CreateFontW(-fontSize, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE,
		FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
		ANTIALIASED_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
	HGDIOBJ oldFont = (dc && font) ? SelectObject(dc, font) : NULL;
	if (!dc || !dib || !dibPixels || !font || !oldBitmap || !oldFont) {
		if (oldFont) SelectObject(dc, oldFont);
		if (oldBitmap) SelectObject(dc, oldBitmap);
		if (font) DeleteObject(font);
		if (dib) DeleteObject(dib);
		if (dc) DeleteDC(dc);
		HeapFree(GetProcessHeap(), 0, wideText);
		return luaL_error(L, "could not create system-font text bitmap");
	}

	memset(dibPixels, 0, (size_t)width * height * 4);
	SetBkMode(dc, OPAQUE);
	SetBkColor(dc, RGB(0, 0, 0));
	SetTextColor(dc, RGB(255, 255, 255));
	RECT textRect = { 0, 0, width, height };
	DrawTextW(dc, wideText, -1, &textRect,
		DT_LEFT | DT_TOP | DT_WORDBREAK | DT_NOPREFIX | DT_EXPANDTABS);
	size_t dibSize = (size_t)width * height * 4;
	void *dibCopy = HeapAlloc(GetProcessHeap(), 0, dibSize);
	if (!dibCopy) {
		SelectObject(dc, oldFont);
		SelectObject(dc, oldBitmap);
		DeleteObject(font);
		DeleteObject(dib);
		DeleteDC(dc);
		HeapFree(GetProcessHeap(), 0, wideText);
		return luaL_error(L, "could not allocate text image buffer");
	}
	memcpy(dibCopy, dibPixels, dibSize);
	SelectObject(dc, oldFont);
	SelectObject(dc, oldBitmap);
	DeleteObject(font);
	DeleteObject(dib);
	DeleteDC(dc);
	HeapFree(GetProcessHeap(), 0, wideText);

	LPDIRECT3DTEXTURE9 texture = NULL;
	HRESULT result = IDirect3DDevice9_CreateTexture(d3dDevice,
		(UINT)width, (UINT)height, 1, 0, D3DFMT_A8R8G8B8,
		D3DPOOL_MANAGED, &texture, NULL);
	if (result != D3D_OK || !texture) {
		HeapFree(GetProcessHeap(), 0, dibCopy);
		return luaL_error(L, "could not create Direct3D text texture (0x%08lx)",
			(unsigned long)result);
	}

	D3DLOCKED_RECT locked;
	result = IDirect3DTexture9_LockRect(texture, 0, &locked, NULL, 0);
	if (result != D3D_OK) {
		IDirect3DTexture9_Release(texture);
		HeapFree(GetProcessHeap(), 0, dibCopy);
		return luaL_error(L, "could not lock Direct3D text texture (0x%08lx)",
			(unsigned long)result);
	}
	// DIB pixels are BGRA; use their grayscale coverage as texture alpha.
	// White RGB lets the draw call tint the text with any feedback color.
	for (int y = 0; y < height; ++y) {
		const uint8_t *src = (const uint8_t*)dibCopy + (size_t)y * width * 4;
		D3DCOLOR *dst = (D3DCOLOR*)((uint8_t*)locked.pBits
			+ (size_t)y * locked.Pitch);
		for (int x = 0; x < width; ++x) {
			unsigned alpha = (src[x * 4] + src[x * 4 + 1]
				+ src[x * 4 + 2]) / 3;
			dst[x] = D3DCOLOR_ARGB(alpha, 255, 255, 255);
		}
	}
	IDirect3DTexture9_UnlockRect(texture, 0);
	HeapFree(GetProcessHeap(), 0, dibCopy);

	TEXTUREHANDLE *handle = (TEXTUREHANDLE*)lua_newuserdata(
		L, sizeof(TEXTUREHANDLE));
	handle->texture = texture;
	if (luaL_newmetatable(L, TEXTURE_METATABLE)) {
		lua_pushcfunction(L, l_textTextureGc);
		lua_setfield(L, -2, "__gc");
	}
	lua_setmetatable(L, -2);
	return 1;
}

static int l_drawTextTexture(lua_State *L)
{
	TEXTUREHANDLE *handle = (TEXTUREHANDLE*)luaL_checkudata(
		L, 1, TEXTURE_METATABLE);
	FLOAT left = (FLOAT)luaL_checknumber(L, 2);
	FLOAT top = (FLOAT)luaL_checknumber(L, 3);
	FLOAT right = (FLOAT)luaL_checknumber(L, 4);
	FLOAT bottom = (FLOAT)luaL_checknumber(L, 5);
	D3DCOLOR color = (D3DCOLOR)luaL_checkint(L, 6);
	if (!handle->texture || !d3dDevice) return 0;
	// D3D9 rasterizes pixel centers at half-integers; compensate for that
	// so the font texture remains sharp when drawn at its native size.
	TEXTUREDVERTEX vertices[] = {
		{ left - 0.5f,  top - 0.5f,    0.0f, 1.0f, color, 0.0f, 0.0f },
		{ right - 0.5f, top - 0.5f,    0.0f, 1.0f, color, 1.0f, 0.0f },
		{ left - 0.5f,  bottom - 0.5f, 0.0f, 1.0f, color, 0.0f, 1.0f },
		{ right - 0.5f, bottom - 0.5f, 0.0f, 1.0f, color, 1.0f, 1.0f },
	};
	HRESULT result = IDirect3DDevice9_SetTexture(d3dDevice, 0,
		(IDirect3DBaseTexture9*)handle->texture);
	if (result == D3D_OK) result = IDirect3DDevice9_SetFVF(d3dDevice,
		D3DFVF_XYZRHW | D3DFVF_DIFFUSE | D3DFVF_TEX1);
	if (result == D3D_OK) result = IDirect3DDevice9_SetTextureStageState(
		d3dDevice, 0, D3DTSS_COLOROP, D3DTOP_MODULATE);
	if (result == D3D_OK) result = IDirect3DDevice9_SetTextureStageState(
		d3dDevice, 0, D3DTSS_COLORARG1, D3DTA_TEXTURE);
	if (result == D3D_OK) result = IDirect3DDevice9_SetTextureStageState(
		d3dDevice, 0, D3DTSS_COLORARG2, D3DTA_DIFFUSE);
	if (result == D3D_OK) result = IDirect3DDevice9_SetTextureStageState(
		d3dDevice, 0, D3DTSS_ALPHAOP, D3DTOP_MODULATE);
	if (result == D3D_OK) result = IDirect3DDevice9_SetTextureStageState(
		d3dDevice, 0, D3DTSS_ALPHAARG1, D3DTA_TEXTURE);
	if (result == D3D_OK) result = IDirect3DDevice9_SetTextureStageState(
		d3dDevice, 0, D3DTSS_ALPHAARG2, D3DTA_DIFFUSE);
	if (result == D3D_OK) result = IDirect3DDevice9_SetSamplerState(
		d3dDevice, 0, D3DSAMP_MINFILTER, D3DTEXF_POINT);
	if (result == D3D_OK) result = IDirect3DDevice9_SetSamplerState(
		d3dDevice, 0, D3DSAMP_MAGFILTER, D3DTEXF_POINT);
	if (result == D3D_OK) result = IDirect3DDevice9_DrawPrimitiveUP(
		d3dDevice, D3DPT_TRIANGLESTRIP, 2, vertices, sizeof(TEXTUREDVERTEX));
	IDirect3DDevice9_SetTexture(d3dDevice, 0, NULL);
	IDirect3DDevice9_SetFVF(d3dDevice, CUSTOMFVF);
	IDirect3DDevice9_SetTextureStageState(d3dDevice, 0, D3DTSS_COLOROP,
		D3DTOP_SELECTARG1);
	IDirect3DDevice9_SetTextureStageState(d3dDevice, 0, D3DTSS_COLORARG1,
		D3DTA_DIFFUSE);
	IDirect3DDevice9_SetTextureStageState(d3dDevice, 0, D3DTSS_ALPHAOP,
		D3DTOP_SELECTARG1);
	IDirect3DDevice9_SetTextureStageState(d3dDevice, 0, D3DTSS_ALPHAARG1,
		D3DTA_DIFFUSE);
	lua_pushinteger(L, (lua_Integer)result);
	return 1;
}

// create vertices that render as a square when using D3DPT_TRIANGLELIST
#define squareTriangleList(left, top, right, bottom, color) \
	{ left,  top,    1.0f, 1.0f, color }, \
	{ right, top,    1.0f, 1.0f, color }, \
	{ left,  bottom, 1.0f, 1.0f, color }, \
	{ right, top,    1.0f, 1.0f, color }, \
	{ right, bottom, 1.0f, 1.0f, color }, \
	{ left,  bottom, 1.0f, 1.0f, color }

HRESULT drawHitbox(
	FLOAT outerLeftX, FLOAT outerTopY, FLOAT outerRightX, FLOAT outerBottomY,
	FLOAT innerLeftX, FLOAT innerTopY, FLOAT innerRightX, FLOAT innerBottomY,
	D3DCOLOR edge, D3DCOLOR fill)
{
	HRESULT result;
	static VOID *pVoid;
	CHECK_RESULT(IDirect3DVertexBuffer9_Lock(boxBuffer, 0, 0, (void**)&pVoid, 0));
	CUSTOMVERTEX vertices[] = {
		// inside fill
		squareTriangleList(innerLeftX,  innerTopY,    innerRightX, innerBottomY, fill),
		// left edge
		squareTriangleList(outerLeftX,  outerTopY,    innerLeftX,  outerBottomY, edge),
		// right edge
		squareTriangleList(innerRightX, outerTopY,    outerRightX, outerBottomY, edge),
		// top edge
		squareTriangleList(innerLeftX,  outerTopY,    innerRightX, innerTopY,    edge),
		// bottom edge
		squareTriangleList(innerLeftX,  innerBottomY, innerRightX, outerBottomY, edge)
	};
	memcpy(pVoid, vertices, sizeof(vertices));
	CHECK_RESULT(IDirect3DVertexBuffer9_Unlock(boxBuffer));
	CHECK_RESULT(IDirect3DDevice9_SetStreamSource(d3dDevice, 0, boxBuffer, 0, sizeof(CUSTOMVERTEX)));
	CHECK_RESULT(IDirect3DDevice9_DrawPrimitive(d3dDevice, D3DPT_TRIANGLELIST, 0, 10));
	done:
	return result;
}

#undef squareTriangleList

// Takes 10 arguments:
// - X/Y of outer top-left corner
// - X/Y of outer bottom-right corner
// - X/Y of inner top-left corner
// - X/Y of inner bottom-right corner
// - Box edge color
// - Box fill color
// Returns 1 value: HRESULT from last D3D call made (stops at first failed call)
static int l_drawHitbox(lua_State *L)
{
	HRESULT result = drawHitbox(
		luaL_checknumber(L, 1), luaL_checknumber(L, 2),
		luaL_checknumber(L, 3), luaL_checknumber(L, 4),
		luaL_checknumber(L, 5), luaL_checknumber(L, 6),
		luaL_checknumber(L, 7), luaL_checknumber(L, 8),
		(D3DCOLOR)luaL_checkint(L, 9), (D3DCOLOR)luaL_checkint(L, 10)
	);
	lua_pushinteger(L, (lua_Integer)result);
	return 1;
}

// Takes 4 arguments: Left/top and right/bottom corners of new scissor clipping area
// Returns 1 value: HRESULT from SetScissorRect() call
static int l_setScissor(lua_State *L)
{
	int left  = luaL_checkint(L, 1), top    = luaL_checkint(L, 2);
	int width = luaL_checkint(L, 3), height = luaL_checkint(L, 4);
	scissorRect.left = (LONG)left;
	scissorRect.top = (LONG)top;
	scissorRect.right = (LONG)width;
	scissorRect.bottom = (LONG)height;
	HRESULT result = IDirect3DDevice9_SetScissorRect(d3dDevice, &scissorRect);
	lua_pushinteger(L, (lua_Integer)result);
	return 1;
}

// Takes 1 optional argument: Clear color (default transparent)
// Returns 1 value: HRESULT from Clear() call
static int l_clearFrame(lua_State *L)
{
	D3DCOLOR clearColor;
	if (!lua_isnoneornil(L, 1)) { clearColor = (D3DCOLOR)luaL_checkint(L, 1); }
	else { clearColor = D3DCOLOR_RGBA(0, 0, 0, 0); }
	HRESULT result = IDirect3DDevice9_Clear(d3dDevice,
		0, NULL, D3DCLEAR_TARGET, clearColor, 1.0f, 0);
	lua_pushinteger(L, (lua_Integer)result);
	return 1;
}

// Takes 1 optional argument: Clear color (default transparent)
// Returns 1 value: HRESULT from last D3D call made (stops at first failed call)
static int l_beginFrame(lua_State *L)
{
	HRESULT result;
	l_clearFrame(L);
	CHECK_RESULT((HRESULT)lua_tointeger(L, -1));
	CHECK_RESULT(IDirect3DDevice9_BeginScene(d3dDevice));
	result = IDirect3DDevice9_SetFVF(d3dDevice, CUSTOMFVF);
	done:
	lua_pushinteger(L, (lua_Integer)result);
	return 1;
}

// Takes 4 arguments: Top-left and bottom-right coords of source rect
// Returns 1 value: HRESULT from last D3D call made (stops at first failed call)
static int l_endFrame(lua_State *L)
{
	HRESULT result;
	RECT sourceRect;
	sourceRect.left = (LONG)luaL_checkint(L, 1);
	sourceRect.top = (LONG)luaL_checkint(L, 2);
	sourceRect.right = (LONG)luaL_checkint(L, 3);
	sourceRect.bottom = (LONG)luaL_checkint(L, 4);
	CHECK_RESULT(IDirect3DDevice9_EndScene(d3dDevice));
	result = IDirect3DDevice9_Present(d3dDevice, &sourceRect, NULL, NULL, NULL);
	done:
	lua_pushinteger(L, (lua_Integer)result);
	return 1;
}

const luaL_Reg lib_directX[] = {
	{ "setupD3D", l_setupD3D },
	{ "resetD3D", l_resetD3D },
	{ "rect", l_DXRectangle },
	{ "createTextTexture", l_createTextTexture },
	{ "drawTextTexture", l_drawTextTexture },
	{ "hitbox", l_drawHitbox },
	{ "setScissor", l_setScissor },
	{ "clearFrame", l_clearFrame },
	{ "beginFrame", l_beginFrame },
	{ "endFrame", l_endFrame },
	{ NULL, NULL } // sentinel
};
