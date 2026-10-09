using System.Numerics;
using Hzs.Decima.Assets;
using Hzs.Decima.Core;

namespace Hzs.Decima.World;

/// <summary>WorldTransform (WorldPosition doubles + RotMatrix columns) helpers, HZD and Godot space.</summary>
public static class WorldXf
{
    /// <summary>HZD-space row-vector matrix of a WorldTransform struct (rotation columns become rows).</summary>
    public static Matrix4x4 Hzd(Obj wt)
    {
        var p = wt.Struct("Position");
        var r = wt.Struct("Orientation");
        Obj c0 = r.Struct("Col0"), c1 = r.Struct("Col1"), c2 = r.Struct("Col2");
        return new Matrix4x4(
            c0.Float("X"), c0.Float("Y"), c0.Float("Z"), 0,
            c1.Float("X"), c1.Float("Y"), c1.Float("Z"), 0,
            c2.Float("X"), c2.Float("Y"), c2.Float("Z"), 0,
            (float)p.Double("X"), (float)p.Double("Y"), (float)p.Double("Z"), 1);
    }

    public static Vector3 HzdPos(Obj wt)
    {
        var p = wt.Struct("Position");
        return new Vector3((float)p.Double("X"), (float)p.Double("Y"), (float)p.Double("Z"));
    }

    public static Vector3 GodotPos(Obj wt) => Space.P(HzdPos(wt));

    public static Matrix4x4 Godot(Obj wt) => Space.M(Hzd(wt));

    /// <summary>Yaw in degrees around Godot +Y of a transform's forward axis (HZD +Y forward -> Godot -Z).</summary>
    public static float GodotYawDeg(Matrix4x4 g)
    {
        var fwd = Vector3.TransformNormal(-Vector3.UnitZ, g);
        return (float)(Math.Atan2(-fwd.X, -fwd.Z) * 180 / Math.PI);
    }

    public static (int X, int Y) TileOf(Vector3 hzdPos) =>
        ((int)Math.Floor(hzdPos.X / TerrainReader.TileSize), (int)Math.Floor(hzdPos.Y / TerrainReader.TileSize));
}
