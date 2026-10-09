namespace Hzs.Decima.Core;

// Hand-written layouts: gameplay resources read for the machines/systems sheets (AI, destructibility, streaming).
public static partial class Layouts
{
    private static void RegisterGame()
    {
        L(0xF34A76FAD0A1E0D7, "PrefetchList", "Files:Array<String> Sizes:Array<int> Links:Array<int>");
        L(0xC294F29914483371, "DestructibilityResource", "Name:String Invulnerable:bool InitialHealth:float DieAtZeroHealth:bool InitialStates:Array<Ref> ConvertedParts:Array<Ref> DefaultDamagePart:Ref", partial: true);
        L(0xF3A071B36219C695, "DestructibilityPart", "Name:String Enabled:bool Health:float DamageSponge:bool DamageToEntityMultiplier:float ClampCoreDamageToPartHealth:bool LimitMaxCoreHealth:bool BoneName:String LocalMatrix:Mat44 RandomLocalMatrix:Ref InitialState:Ref TagProperties:Array<Ref>");
        L(0x6FEEB5337B0DD45B, "AIIndividualResource", "Name:String CombatSituationResource:Ref Perception:Ref", partial: true);
        L(0xB7F0161639E813FC, "AIPerceptionResource", "Name:String IgnoreProjectiles:bool PerceptionFalloffSpeed:float SensorSets:Array<Ref> DisableRadarSensorsOnInitialize:bool");
        L(0xB7EAB72CD19D95B6, "AISensorSetResource", "Name:String Idle:Array<Ref> PresenceSuspected:Array<Ref> PresenceConfirmed:Array<Ref> Alert:Array<Ref> UnitImmediateSuspicionDistance:float UnitImmediateConfirmationDistance:float UnitImmediateIdentificationDistance:float");
        L(0x2B87E15B0B4DD7BF, "AIVisualSensor", "Name:String DirectUnitDetectionDistance:float DirectHeadingAngle:float DirectPitchAngle:float DirectWidth:float DirectHeight:float DirectPerpendicularFactor:Ref DirectHeadingSensitivity:Ref DirectPitchSensitivity:Ref TerrainReappearanceWpsMaxDistance:float PeripheralUnitDetectionDistance:float PeripheralHeadingAngle:float PeripheralStimulusSizeModifier:float PeripheralPerpendicularFactor:Ref PeripheralHeadingSensitivity:Ref PeripheralPitchSensitivity:Ref LightThreshold:float LightInfluence:float AtmosphereInfluence:float SeeThroughCloakDistance:float SeeThroughCloakDistancePeripheral:float SeeThroughAtmosphereDistance:float SeeThroughAtmosphereDistancePeripheral:float NearbyFriendlyDistance:float NearbyFriendlyInterval:float TPAExactSeeThroughDistanceModifier:float");
        L(0x440E95D410A6EA03, "AIAuralSensor", "Name:String UnitDetectionDistance:float Range:float");
        L(0x58834E044E7D8AA2, "TileBasedStreamingStrategyResource", "Name:String BlacklistedTypes:Array<String> WhitelistedTypes:Array<String> WhitelistedObjects:Array<Ref> HintAllTiles:bool TileSize:int TileBorder:int GridSize:ISize Tiles:Array<Ref> HighLODDiameter:int LowLODDiameter:int");
        L(0x78C2D25A923D336D, "EntityResource", "Name:String", lead: "Lockable:bool ZoomLockable:bool", partial: true);
    }
}
