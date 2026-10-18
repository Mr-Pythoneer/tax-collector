using System.Text.Json;
using System.Text.Json.Serialization;

namespace TaxCore;

/// Shared JSON setup. Dates are ISO-8601 (UTC); string enums are camelCase to
/// match the Mac's rawValues ("accepted", "guardianApproved", "weeks"…). The
/// tagged-union types (TaskSource, TaskStatus, BlackbaudMark) use the same
/// nested shape the Swift Codable layer writes, e.g. {"blackbaud":{"uid":"…"}}.
public static class Json
{
    public static readonly JsonSerializerOptions Options = Build(indented: true);
    public static readonly JsonSerializerOptions Compact = Build(indented: false);

    private static JsonSerializerOptions Build(bool indented)
    {
        var o = new JsonSerializerOptions
        {
            WriteIndented = indented,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            // Older save files that are missing newer fields still load.
            PropertyNameCaseInsensitive = true,
        };
        o.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        o.Converters.Add(new TaskSourceConverter());
        o.Converters.Add(new TaskStatusConverter());
        o.Converters.Add(new BlackbaudMarkConverter());
        return o;
    }

    public static T? Decode<T>(string text) => JsonSerializer.Deserialize<T>(text, Options);
    public static string Encode<T>(T value) => JsonSerializer.Serialize(value, Options);
}
