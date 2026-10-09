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

        // placements (WorldNode subclasses serialize Orientation before the ObjectUUID)
        L(0, "PODVariant", "Type:e1 BinaryValue:uint32");
        L(0, "PrefabPODAttributeOverride", "Group:String Name:String Value:PODVariant");
        L(0, "PrefabShaderOverride", "VariableID:String ElementCount:int Value:Vec4");
        L(0, "PrefabObjectOverrides", "RuntimeObject:GGUUID Orientation:Mat44 IsRemoved:bool IsTransformOverridden:bool AttributeOverrides:Array<PrefabPODAttributeOverride> ShaderOverrides:Array<PrefabShaderOverride>");
        L(0, "SpawnSetupOverride", "SpawnSetupPlaceholder:Ref SpawnSetupConcrete:Ref");
        L(0, "SpawnFactOverride", "SpawnSource:Ref FactValues:Array<Ref>");
        L(0xA59DE4F11A25009F, "SceneInstance", "ChildTransformsRelative:bool Overrides:Array<PrefabObjectOverrides> Name:String SpawnSetupOverrides:Array<SpawnSetupOverride> SpawnFactOverrides:Array<SpawnFactOverride> Prefab:Ref", lead: "Orientation:WorldTransform", partial: true);
        L(0x86D02689FFE844D3, "AIMarker", "Name:String", lead: "Orientation:WorldTransform", partial: true);
        L(0x3B945C8073AA4A01, "StaticMeshInstance", "CullInfo:DrawableCullInfo LodDistanceScale:float Name:String Resource:Ref", lead: "Orientation:WorldTransform", partial: true);
        L(0x9F60BF4DB3485DA2, "PrefabInstance", "ChildTransformsRelative:bool Overrides:Array<PrefabObjectOverrides> Prefab:Ref", lead: "Orientation:WorldTransform");
        L(0xAB34641EA545AAD3, "PrefabResource", "ObjectCollection:Ref");
        L(0xA97082C73B2BC4BB, "ObjectCollection", "Objects:Array<Ref>");
        L(0, "MultiMeshResourcePart", "Mesh:Ref Transform:WorldTransform");

        // procedural vegetation (placement.core)
        L(0xE605F6EC1EE0979D, "PlacementLayer", "PlacementDistance:float CreationOrder:int GroupingFlags:e4 BakedData:Ref ProcData:Ref");
        L(0x2B9D634C4B5A2EBA, "PlacementProceduralData", "DensityProgram:Ref Placement:Ref ChunkSizeSetting:e4 UsageMask:e4 UseBlendedShadows:bool StencilScale:float DensityScale:float HeightWorldDataType:Ref");
        L(0x739AB497DD04F1B5, "PlacementSet", "Name:String DensityGraph:Ref Children:Array<Ref> DensityBehavior:e4 NormalizeDensity:bool DensityScale:float HeightMap:Ref");
        // density graph nodes (only what decides where a species may grow: ecotope effect curves)
        L(0xC668B09FA794005F, "CurveResource", "Name:String Points:Array<Vec2> Tangents:Array<float> Smooth:bool");
        L(0x55866559C84E2E51, "DensityCurveLookup", "Name:String Map:Ref Curve:Ref");
        L(0xCF14BCDFC23C50FB, "DensityMultiply", "Name:String Inputs:Array<Ref>");
        L(0x512BDCB5C8D28807, "DensityWorldDataMap", "Name:String Curve:Ref WorldDataType:Ref Channel:e4");
        L(0xE2D58392C3A704E7, "DensityInvert", "Name:String InputDensity:Ref");
        L(0x0DA8EE7190FB26F7, "MeshPlacement", "Name:String DensityGraph:Ref UsageMask:e4 DensityBehavior:e4 DensityScale:float ChunkSize:e4 MaxSlope:float MinSlope:float RotationType:e4 RotationOffset:float RotationVariance:float BaseElevation:float ElevationVariance:float WanderingDistance:float RandomTiltFactor:float TerrainTiltFactor:float UpTiltFactor:float ManualTilt:Vec3 Scale:float ScaleVariance:float ApplyShadowBlending:bool MaxRenderDistance:float Footprint:float Mesh:Ref PlacementTargets:Array<Ref>");

        // robot sites
        L(0, "IRange", "Min:int Max:int");
        L(0x6BDCF662A3A5FB55, "SceneResource", "ActivateCondition:Ref SubScenes:Array<Ref> NonStreamingObjectCollection:Ref ObjectCollection:Ref", partial: true);
        L(0x5E6533FDF6A8641E, "AIBehaviorGroup", "ChildTransformsRelative:bool SpawnPoints:Array<Ref> Members:Array<Ref> SpawnCommands:Array<Ref> ExtraComponents:Array<Ref> AutoSpawn:bool JoinSceneGroup:bool", lead: "Orientation:WorldTransform");
        L(0xB8AA4CF170323A31, "AIBehaviorGroupMember", "SpawnSetup:Ref Amount:IRange NavmeshPlacementType:e1 SpawnRange:FRange SpawnHeadingRange:FRange ExtraComponents:Array<Ref> SpawnCommands:Array<Ref>");
        L(0x3DA07F69078D2462, "AIDefendAreaSet", "ChildTransformsRelative:bool Name:String Nodes:Array<Ref>", lead: "Orientation:WorldTransform");
        L(0x149112F396C8A1F4, "AIDefendArea", "ChildTransformsRelative:bool IdleRadius:float", lead: "Orientation:WorldTransform", partial: true);
        L(0x57105BDC7F56C798, "DefendSpawnCommand", "DefendAreaSet:Ref", lead: "Orientation:WorldTransform");
        L(0x6174587B926EDAD5, "MultiMeshResource", "Name:String BoundingBox:BoundingBox3 CullInfo:DrawableCullInfo MeshHierarchyInfo:MeshHierarchyInfo StaticDataBlockSize:uint Parts:Array<MultiMeshResourcePart>");
    }
}
