namespace Hzs.Decima.Core;

// Hand-written layouts: world terrain and streaming tiles.
public static partial class Layouts
{
    private static void RegisterWorld()
    {
        L(0, "TerrainTileMaterialData", "LookupDataPath:String LookupDataBlockSize:int LookupValueBuffer:Ref LookupDataOffsets:Vec4 LookupDataBuffer:Ref");
        L(0, "TerrainDataNode", "PackedData0:uint16 PackedData1:uint16 PackedData2:uint16");
        L(0x1026D74A58C61D2C, "WorldDataTextureMap", "Name:String GridCoordinates:IVec2 ResultTexture:Ref Entries:Array<Ref> SurfaceCacheData:Array<uint8> SurfaceCacheFormat:e4");
        L(0x203BC181D32F2A52, "WorldDataTextureMapEntry", "Name:String Type:Ref Channel:e4");
        L(0xF45C6BA16B2A4F32, "TerrainTileData", "Name:String GridCoordinates:IVec2 MinimumNodeSize:int MaterialLODType:e4 MaterialLODCount:int TerrainMaterialData:TerrainTileMaterialData HoleBBoxes:Array<BoundingBox2> HoleDataBuffer:Ref MappedHeightRange:FRange", partial: true);
        L(0x74B3858807F45015, "Terrain", "CullInfo:DrawableCullInfo LodDistanceScale:float TerrainDataNodes:Array<TerrainDataNode> TerrainHeightRange:FRange TileCount:int TileStart:IVec2", lead: "Orientation:WorldTransform", partial: true);
        L(0xDA6B57CA4988B635, "StreamingTileResource", "Coordinates:IVec2 States:Array<Ref>");
        L(0xD45D0D5AB1E9F962, "StreamingTileStateResource", "LODs:Array<Ref>");
    }
}
