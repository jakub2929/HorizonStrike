using System.Numerics;

namespace Hzs.Decima.Assets;

/// <summary>
/// HZD (Decima) space -> Godot space. HZD is right-handed, Z up, characters face +Y, right is +X; Godot is
/// right-handed, Y up, forward -Z. Mapping: godot = (x, z, -y) (a proper rotation, handedness preserved).
/// Matrices use System.Numerics row-vector convention (v' = v * M).
/// </summary>
public static class Space
{
    /// <summary>v_godot = v_hzd * C.</summary>
    public static readonly Matrix4x4 C = new(1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1);
    public static readonly Matrix4x4 Ci = Matrix4x4.Transpose(C);

    public static Vector3 P(Vector3 h) => new(h.X, h.Z, -h.Y);
    public static Vector3 P(float x, float y, float z) => new(x, z, -y);
    public static Vector3 P(double x, double y, double z) => new((float)x, (float)z, (float)-y);

    /// <summary>Transform expressed in HZD space -> same transform in Godot space.</summary>
    public static Matrix4x4 M(Matrix4x4 h) => Ci * h * C;

    /// <summary>Converts xyz triplets in place.</summary>
    public static void Points(float[] xyz)
    {
        for (var i = 0; i + 2 < xyz.Length; i += 3)
        {
            var y = xyz[i + 1];
            xyz[i + 1] = xyz[i + 2];
            xyz[i + 2] = -y;
        }
    }

    /// <summary>Godot Transform3D as 12 floats: basis columns x, y, z then origin (column-major, cell.json "xf").</summary>
    public static float[] Xf(Matrix4x4 g) => [g.M11, g.M12, g.M13, g.M21, g.M22, g.M23, g.M31, g.M32, g.M33, g.M41, g.M42, g.M43];
}
