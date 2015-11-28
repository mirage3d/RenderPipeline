#version 430

#pragma include "Includes/Configuration.inc.glsl"
#pragma include "Includes/PositionReconstruction.inc.glsl"
#pragma include "Includes/LightCulling.inc.glsl"
#pragma include "Includes/LightData.inc.glsl"
#pragma include "Includes/Structures/Frustum.struct.glsl"

out vec4 result;

uniform isamplerBuffer CellListBuffer;
uniform writeonly iimageBuffer perCellLightsBuffer;

uniform samplerBuffer AllLightsData;
uniform int maxLightIndex;

// #define PROJ_MAT trans_view_of_mainCam_to_clip_of_mainCam
#define PROJ_MAT currentProjMat
// uniform mat4 PROJ_MAT;
uniform mat4 currentViewMatZup;

void main() {

    int sliceWidth = 512;
    ivec2 coord = ivec2(gl_FragCoord.xy);
    int idx = coord.x + coord.y * sliceWidth + 1;
    int numTotalCells = texelFetch(CellListBuffer, 0).x;

    if (idx > numTotalCells) {
        result = vec4(0.2, 0, 0, 1);
        return;
    }

    int packedCellData = texelFetch(CellListBuffer, idx).x;

    int cellX = packedCellData & 0x3FF;
    int cellY = (packedCellData >> 10) & 0x3FF;
    int cellSlice = (packedCellData >> 20) & 0x3FF;

    float linearDepthStart = getLinearDepthFromSlice(cellSlice);
    float linearDepthEnd = getLinearDepthFromSlice(cellSlice + 1);

    int storageOffs = (MAX_LIGHTS_PER_CELL+1) * idx;
    int numRenderedLights = 0;

    // Per tile bounds
    ivec2 precomputeSize = ivec2(LC_TILE_AMOUNT_X, LC_TILE_AMOUNT_Y);
    ivec2 patchSize = ivec2(LC_TILE_SIZE_X, LC_TILE_SIZE_Y);
    ivec2 virtualScreenSize = precomputeSize * patchSize;
    vec2 tileScale = vec2(virtualScreenSize) / vec2( 2.0 * patchSize);
    vec2 tileBias = tileScale - vec2(cellX, cellY) - 0.5;

    // Build frustum
    // Based on http://gamedev.stackexchange.com/questions/67431/deferred-tiled-shading-tile-frusta-calculation-in-opengl
    // (Which is based on DICE's presentation)
    // vec4 frustumRL = vec4(-PROJ_MAT[0][0] * tileScale.x, 0.0f, tileBias.x, 0.0f);
    vec4 frustumRL = vec4(-PROJ_MAT[0][0] * tileScale.x, PROJ_MAT[0][1], tileBias.x, PROJ_MAT[0][3]);
    // vec4 frustumTL = vec4(0.0f, -PROJ_MAT[2][1] * tileScale.y, tileBias.y, 0.0f);
    vec4 frustumTL = vec4(PROJ_MAT[1][0], -PROJ_MAT[1][1] * tileScale.y, tileBias.y, PROJ_MAT[3][3]);

    // const vec4 frustumOffset = vec4(0.0f, 0.0f, -1.0f, 0.0f);
    // const vec4 frustumOffset = vec4(PROJ_MAT[3][0], PROJ_MAT[3][1], -1.0f, PROJ_MAT[3][3]);
    const vec4 frustumOffset = vec4(PROJ_MAT[3][0], PROJ_MAT[3][1], -1.0f, PROJ_MAT[3][3]);

    // Calculate frustum planes
    Frustum frustum;
    frustum.right  = normalize_without_w(frustumOffset - frustumRL);
    frustum.left   = normalize_without_w(frustumOffset + frustumRL);
    frustum.top    = normalize_without_w(frustumOffset - frustumTL);
    frustum.bottom = normalize_without_w(frustumOffset + frustumTL);

    frustum.nearPlane = vec4(0, 0, -1.0, -linearDepthStart);
    frustum.farPlane = vec4(0, 0, 1.0, linearDepthEnd);
    frustum.viewMat = currentViewMatZup;

    // Cull all lights
    for (int i = 0; i < maxLightIndex + 1 && numRenderedLights < MAX_LIGHTS_PER_CELL; i++) {
        int dataOffs = i * 4;
        LightData light_data = read_light_data(AllLightsData, dataOffs);
        int lightType = get_light_type(light_data);

        // Null-Light
        if (lightType < 1) continue;

        bool visible = false;
        vec3 lightPos = get_light_position(light_data);

        // if (lightType == LT_POINT_LIGHT) {
            float radius = get_pointlight_radius(light_data);
            visible = isPointLightInFrustum(lightPos, radius, frustum);
        // }

        if (visible) {
            numRenderedLights ++;
            imageStore(perCellLightsBuffer, storageOffs + numRenderedLights, ivec4(i));
        }
    }

    imageStore(perCellLightsBuffer, storageOffs, ivec4(numRenderedLights));
    result = vec4(vec3(idx / 100.0 ), 1.0);
}