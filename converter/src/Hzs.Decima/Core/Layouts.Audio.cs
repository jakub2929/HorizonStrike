namespace Hzs.Decima.Core;

// Hand-written layouts: sounds and music.
public static partial class Layouts
{
    private static void RegisterAudio()
    {
        L(0x685DC980BBF316E3, "WaveResource", "Name:String WaveData:Array<uint8> WaveDataSize:uint SampleRate:int ChannelCount:uint8 Encoding:e4 BitsPerSample:uint16 BitsPerSecond:uint32 BlockAlignment:uint16 FormatTag:uint16 FrameSize:uint16 SampleCount:int",
            lead: "EncodingQuality:e4 IsStreaming:bool UseVBR:bool", binary: true);
        L(0, "MusicSubmixBinding", "TrackName:String Submix:Ref");
        L(0x873D69111E6F7262, "MusicResource", "Name:String StreamingDataHash:Array<uint32> BitRate:int StripSilence:bool StripSilenceThreshold:int SubmixBindings:Array<MusicSubmixBinding> StreamingBankNames:Array<String>", binary: true);
        L(0xA4E899CB6A14AA76, "EnvironmentSound", "Sound:Ref", partial: true);
    }
}
