namespace Hzs.Decima.Core;

// Hand-written layouts: meshes, skeletons, textures, model parts.
public static partial class Layouts
{
    private static void RegisterAssets()
    {
        // structs
        L(0, "MurmurHashValue", "Data0:uint8 Data1:uint8 Data2:uint8 Data3:uint8 Data4:uint8 Data5:uint8 Data6:uint8 Data7:uint8 Data8:uint8 Data9:uint8 Data10:uint8 Data11:uint8 Data12:uint8 Data13:uint8 Data14:uint8 Data15:uint8");
        L(0, "DrawableCullInfo", "Flags:uint32");
        L(0, "MeshHierarchyInfo", "MITNodeSize:uint32 PrimitiveCount:uint32 MeshCount:uint16 StaticMeshCount:uint16 LodMeshCount:uint16 PackedData:uint16");
        L(0, "DrawFlags", "Data:uint32");
        L(0, "PrimitiveResourceFlags", "Flags:uint32");
        L(0, "LodMeshResourcePart", "Mesh:Ref Distance:float");
        L(0, "Joint", "Name:String Parent:String ParentIndex:int16");
        L(0, "OrientationHelper", "Matrix:Mat44 Name:String Index:int");
        L(0, "TextureSetEntry", "CompressMethod:e4 CreateMipMaps:bool ColorSpace:e4 PackingInfo:uint32 TextureType:int Texture:Ref");
        L(0, "TextureSetTextureDesc", "TextureType:e4 Path:String Active:bool GammaSpace:bool StorageType:e4 QualityType:e4 CompressionMethod:e4 Width:int Height:int DefaultColor:FRGBAColor");
        L(0, "HwBindingHandle", "Handle:uint64");
        L(0, "HwSamplerData", "PackedData:uint32");
        L(0, "RenderTechniqueState", "PackedData:uint16 PackedDepthBias:HalfFloat PackedColorMask:uint32");
        L(0, "SRTBindingCache", "TextureBindingMask:uint8 BindingDataMask:uint16 SRTEntriesMask:uint64 BindingDataIndices:Array<uint16> SRTEntryHandles:Array<HwBindingHandle>");
        L(0, "SamplerBindingWithHandle", "BindingNameHash:uint32 SamplerData:HwSamplerData SamplerBindingHandle:HwBindingHandle");
        L(0, "TextureBindingWithHandle", "BindingNameHash:uint32 BindingSwizzleNameHash:uint32 SamplerNameHash:uint32 PackedData:uint32 TextureResource:Ref TextureBindingHandle:HwBindingHandle SwizzleBindingHandle:HwBindingHandle");
        L(0, "VariableBindingWithHandle", "BindingNameHash:uint32 VariableIDHash:uint32 VariableType:e1 VariableData0:uint32 VariableData1:uint32 VariableData2:uint32 VariableData3:uint32 VarBindingHandle:HwBindingHandle");
        L(0, "RenderTechniqueID", "Hash:uint64");
        L(0, "RenderTechnique", "RenderTechniqueState:RenderTechniqueState SRTBindingCache:SRTBindingCache TechniqueType:e4 WorldDataBingingMask:uint64 GPUSkinned:bool WriteGlobalVertexCache:bool InitiallyEnabled:bool MaterialLayerID:uint32 SamplerBindings:Array<SamplerBindingWithHandle> TextureBindings:Array<TextureBindingWithHandle> VariableBindings:Array<VariableBindingWithHandle> Shader:Ref ID:RenderTechniqueID");
        L(0, "RenderTechniqueSet", "RenderTechniques:Array<RenderTechnique> Type:e4 EffectType:e4 AvailableTechniquesMask:uint32 InitiallyEnabledTechniquesMask:uint32");
        L(0, "VertexElementSet", "SetData:uint32");
        L(0, "SkinnedModelLOD", "Distance:float DisableHipsIK:bool DisableTerrainPredictionFootIK:bool DisableHeadIK:bool DisablePoseDeformer:bool DisableForceFields:bool LowDetailTerrainDetection:bool DisableAnimationManagerOnExternalAnimation:bool");

        // objects
        L(0x5F5D6D208C0B35B4, "LodMeshResource", "Name:String BoundingBox:BoundingBox3 CullInfo:DrawableCullInfo MeshHierarchyInfo:MeshHierarchyInfo StaticDataBlockSize:uint MaxDistance:float Meshes:Array<LodMeshResourcePart>");
        L(0x98681A4BAF459D6E, "RegularSkinnedMeshResource", "Name:String BoundingBox:BoundingBox3 CullInfo:DrawableCullInfo MeshHierarchyInfo:MeshHierarchyInfo StaticDataBlockSize:uint Skeleton:Ref OrientationHelpers:Ref DrawFlags:DrawFlags DeformerType:e4 SkinnedMeshBoneBindings:Ref SkinnedMeshBoneBoundingBoxes:Ref PositionBoundsScale:Vec3 PositionBoundsOffset:Vec3 SkinInfo:Ref Primitives:Array<Ref> RenderFxResources:Array<Ref>");
        L(0xEC711C9C5BD00A78, "StaticMeshResource", "Name:String BoundingBox:BoundingBox3 CullInfo:DrawableCullInfo MeshHierarchyInfo:MeshHierarchyInfo StaticDataBlockSize:uint DrawFlags:DrawFlags Primitives:Array<Ref> RenderEffects:Array<Ref> OrientationHelpers:Ref SimulationInfo:Ref SupportsInstanceRendering:bool");
        L(0x033885CF170B7D2C, "SkinnedMeshBoneBindings", "BoneNames:Array<String> JointIndexList:Array<uint16> InverseBindMatrices:Array<Mat44> DataHash:MurmurHashValue");
        L(0xF32E55727166F8EC, "RenderingPrimitiveResource", "Flags:PrimitiveResourceFlags VertexArray:Ref IndexArray:Ref BoundingBox:BoundingBox3 IndexOffset:int SKDTree:Ref StartIndex:int EndIndex:int Hash:uint32 RenderEffects:Ref");
        L(0xBBAB0E0254767A94, "VertexArrayResource", "", binary: true);
        L(0xA94A831CA5252531, "IndexArrayResource", "", binary: true);
        L(0xA6F006CC5BF1574D, "RenderEffectResource", "Name:String TechniqueSets:Array<RenderTechniqueSet> SortMode:e4 SortOrder:e4 EffectType:e4 MakeAccumulationBufferCopy:bool BaseElementSet:VertexElementSet");
        L(0xB7289D0B501DEF01, "Skeleton", "Name:String Joints:Array<Joint>", partial: true);
        L(0x5783A47975078DCB, "SkeletonHelpers", "Name:String Helpers:Array<OrientationHelper> NameHashes:Array<uint>");
        L(0x0E02735CED4F1CDF, "TextureSet", "Name:String Entries:Array<TextureSetEntry> MipMapAddressMode:e4 TextureDesc:Array<TextureSetTextureDesc>");
        L(0xF2E1AFB7052B3866, "Texture", "Name:String", binary: true);
        L(0x8D5A13C6B1CD1C2E, "SkinnedModelResource", "Name:String ModelPartResources:Array<Ref> ViewLayer:e4 ActiveView:e4 Helpers:Array<Ref> LocationProviderID:String HelperName:String Skeleton:Ref LODs:Array<SkinnedModelLOD> DisableCollision:bool UpdateEntityWhilePlayingAnimation:bool AbilityAnimationResource:Ref AbilitySimpleAnimation:Ref AbilityResources:Array<Ref> InitialPose:Pose", partial: true);
        L(0x8EA288ABF194DBD2, "ModelPartResource", "Name:String MeshResource:Ref BoneBoundingBoxes:Ref PhysicsResource:Ref IsSkinned:bool PartMotionType:e4 HelperNode:String");
        L(0xBA6D1D22741BEE33, "DestructibilityPartStateResource", "Name:String ModelPartResource:Ref", partial: true);
    }
}
