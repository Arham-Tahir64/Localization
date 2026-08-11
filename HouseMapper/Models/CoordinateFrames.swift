import simd

/// Rigid-transform helpers for the convention `T_A_B`: coordinates in B to coordinates in A.
enum CoordinateFrames {
    /// Computes `T_M_C = T_M_W · T_W_C`.
    static func mapFromCamera(
        mapFromWorld: simd_float4x4,
        worldFromCamera: simd_float4x4
    ) -> simd_float4x4 {
        simd_mul(mapFromWorld, worldFromCamera)
    }

    /// Computes `T_M_W = T_M_C* · inverse(T_W_C*)` at a global localization match.
    static func mapFromWorld(
        globalMapFromCamera: simd_float4x4,
        worldFromCameraAtMatch: simd_float4x4
    ) -> simd_float4x4 {
        simd_mul(globalMapFromCamera, simd_inverse(worldFromCameraAtMatch))
    }

    static func worldFromCamera(_ cameraFromWorld: simd_float4x4) -> simd_float4x4 {
        simd_inverse(cameraFromWorld)
    }
}

