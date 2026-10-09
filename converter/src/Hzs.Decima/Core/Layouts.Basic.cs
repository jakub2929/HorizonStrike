namespace Hzs.Decima.Core;

// Hand-written layouts: math and common structs (no ObjectUUID, id 0).
public static partial class Layouts
{
    private static void RegisterBasic()
    {
        L(0, "Vec2", "X:float Y:float");
        L(0, "Vec3", "X:float Y:float Z:float");
        L(0, "Vec3Pack", "X:float Y:float Z:float");
        L(0, "Vec4", "X:float Y:float Z:float W:float");
        L(0, "Vec4Pack", "X:float Y:float Z:float W:float");
        L(0, "IVec2", "X:int Y:int");
        L(0, "IVec3", "X:int Y:int Z:int");
        L(0, "ISize", "Width:int Height:int");
        L(0, "Quat", "X:float Y:float Z:float W:float");
        L(0, "Mat44", "Col0:Vec4 Col1:Vec4 Col2:Vec4 Col3:Vec4");
        L(0, "Mat34", "Row0:Vec4Pack Row1:Vec4Pack Row2:Vec4Pack");
        L(0, "RotMatrix", "Col0:Vec3Pack Col1:Vec3Pack Col2:Vec3Pack");
        L(0, "WorldPosition", "X:double Y:double Z:double");
        L(0, "WorldTransform", "Position:WorldPosition Orientation:RotMatrix");
        L(0, "BoundingBox3", "Min:Vec3 Max:Vec3");
        L(0, "BoundingBox2", "Min:Vec2 Max:Vec2");
        L(0, "FRange", "Min:float Max:float");
        L(0, "FRGBColor", "R:float G:float B:float");
        L(0, "FRGBAColor", "R:float G:float B:float A:float");
        L(0, "RGBAColor", "B:uint8 G:uint8 R:uint8 A:uint8");
    }
}
