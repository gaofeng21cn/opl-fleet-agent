using System.Globalization;
using System.Text.Json;

namespace OPLFleetAgent.Core;

public sealed class TokenParserState
{
    internal string? CurrentModel { get; set; }
    internal string? Provider { get; set; }
    internal string? SessionIdFromMeta { get; set; }
    internal string? ForkParentId { get; set; }
    internal string? ChildSessionId { get; set; }
    internal string? ChildProvider { get; set; }
    internal string? ReplaySessionId { get; set; }
    internal bool WaitingForChildTurn { get; set; }
    internal bool ChildIsUserFork { get; set; }
    internal HashSet<string> ChildTaskStartedTurnIds { get; } = new(StringComparer.Ordinal);
    internal UsageTotals? PreviousTotals { get; set; }
    internal UsageTotals? InheritedBaseline { get; set; }
    internal long? InheritedReportedTotal { get; set; }
}

public static class TokenEventParser
{
    internal static readonly string[] RelevantMarkers =
    [
        "\"type\":\"token_count\",\"info\":",
        "\"type\":\"session_meta\",\"payload\":",
        "\"type\":\"turn_context\",\"payload\":",
        "\"type\":\"task_started\"",
    ];

    public static TokenParseBatch Parse(
        IEnumerable<string> lines,
        TokenParserState state,
        string fallbackSessionId)
    {
        var events = new List<UsageEvent>();
        var malformed = 0;

        foreach (var line in lines.Where(ShouldInspect))
        {
            try
            {
                using var document = JsonDocument.Parse(line);
                events.AddRange(Process(document.RootElement, state, fallbackSessionId));
            }
            catch (JsonException)
            {
                malformed++;
            }
        }

        return new TokenParseBatch(events, malformed);
    }

    internal static bool ShouldInspect(string line) =>
        RelevantMarkers.Any(marker => line.Contains(marker, StringComparison.Ordinal));

    private static IReadOnlyList<UsageEvent> Process(
        JsonElement entry,
        TokenParserState state,
        string fallbackSessionId)
    {
        var entryType = StringProperty(entry, "type");
        if (!ObjectProperty(entry, "payload", out var payload))
        {
            return [];
        }

        if (state.WaitingForChildTurn)
        {
            var turnId = StringProperty(payload, "turn_id");
            if (entryType == "turn_context" && ChildTurnStartsOwnSession(state, turnId))
            {
                state.WaitingForChildTurn = false;
                state.ReplaySessionId = null;
                state.ChildTaskStartedTurnIds.Clear();
                state.ChildIsUserFork = false;
                state.SessionIdFromMeta = state.ChildSessionId;
                state.Provider = NonEmpty(state.ChildProvider) ?? state.Provider;
                state.CurrentModel = ResolvedModel(payload) ?? state.CurrentModel;
            }
            else
            {
                RememberReplayState(entryType, payload, state);
                return [];
            }
        }

        if (entryType == "session_meta")
        {
            ProcessSessionMeta(payload, state);
            return [];
        }

        if (entryType == "turn_context")
        {
            state.CurrentModel = ResolvedModel(payload) ?? state.CurrentModel;
            return [];
        }

        if (entryType != "event_msg" || StringProperty(payload, "type") != "token_count" ||
            !ObjectProperty(payload, "info", out var info))
        {
            return [];
        }

        state.CurrentModel = ResolvedModel(payload) ?? state.CurrentModel;
        return ProcessTokenCount(entry, info, state, fallbackSessionId);
    }

    private static void ProcessSessionMeta(JsonElement payload, TokenParserState state)
    {
        var parentId = ResolvedForkParentId(payload);
        if (parentId is not null)
        {
            var id = NonEmpty(StringProperty(payload, "id"));
            var repeatedChild = !state.WaitingForChildTurn && state.ChildSessionId is not null &&
                state.ChildSessionId == id;
            var provider = NonEmpty(StringProperty(payload, "model_provider"));

            state.ForkParentId = parentId;
            state.ChildSessionId = id;
            state.ChildProvider = provider ?? state.ChildProvider;
            state.SessionIdFromMeta = id ?? state.SessionIdFromMeta;
            state.Provider = provider ?? state.Provider;

            if (!repeatedChild)
            {
                state.WaitingForChildTurn = true;
                state.ReplaySessionId = null;
                state.InheritedBaseline = null;
                state.InheritedReportedTotal = null;
                state.ChildTaskStartedTurnIds.Clear();
                state.ChildIsUserFork = StringProperty(payload, "thread_source") == "user";
            }
            return;
        }

        state.SessionIdFromMeta = NonEmpty(StringProperty(payload, "id")) ?? state.SessionIdFromMeta;
        state.Provider =
            NonEmpty(StringProperty(payload, "model_provider")) ?? state.Provider;
        state.CurrentModel = ResolvedModel(payload) ?? state.CurrentModel;
    }

    private static void RememberReplayState(
        string? entryType,
        JsonElement payload,
        TokenParserState state)
    {
        var payloadType = StringProperty(payload, "type");
        if (entryType == "event_msg" && payloadType == "task_started" &&
            NonEmpty(StringProperty(payload, "turn_id")) is { } turnId)
        {
            state.ChildTaskStartedTurnIds.Add(turnId);
        }

        if (entryType == "session_meta" && NonEmpty(StringProperty(payload, "id")) is { } id &&
            id != state.ChildSessionId)
        {
            state.ReplaySessionId = id;
        }

        if (entryType == "event_msg" && payloadType == "token_count" &&
            ObjectProperty(payload, "info", out var info) &&
            UsageProperty(info, "total_token_usage") is { } usage)
        {
            var totals = new UsageTotals(usage);
            state.PreviousTotals = totals;
            state.InheritedBaseline = totals;
            state.InheritedReportedTotal = usage.TotalTokens;
        }
    }

    private static IReadOnlyList<UsageEvent> ProcessTokenCount(
        JsonElement entry,
        JsonElement info,
        TokenParserState state,
        string fallbackSessionId)
    {
        UsageTotals? total = UsageProperty(info, "total_token_usage") is { } totalUsage
            ? new UsageTotals(totalUsage)
            : null;
        UsageTotals? last = UsageProperty(info, "last_token_usage") is { } lastUsage
            ? new UsageTotals(lastUsage)
            : null;

        if (ShouldSkipInherited(total, state))
        {
            return [];
        }
        state.InheritedBaseline = null;
        state.InheritedReportedTotal = null;

        TokenUsage usage;
        UsageTotals? nextTotals;
        if (total is { } current && last is { } increment && state.PreviousTotals is { } previous)
        {
            if (current == previous)
            {
                return [];
            }
            if (current.DeltaFrom(previous) is null &&
                current.LooksLikeStaleRegression(previous, increment))
            {
                return [];
            }
            usage = increment.AsUsage();
            nextTotals = current;
        }
        else if (total is { } initialTotal && last is { } initialIncrement)
        {
            usage = initialIncrement.AsUsage();
            nextTotals = initialTotal;
        }
        else if (total is { } cumulative && state.PreviousTotals is { } prior)
        {
            var delta = cumulative.DeltaFrom(prior);
            if (delta is null)
            {
                state.PreviousTotals = cumulative;
                return [];
            }
            usage = delta.Value.AsUsage();
            nextTotals = cumulative;
        }
        else if (total is { } firstTotal)
        {
            usage = firstTotal.AsUsage();
            nextTotals = firstTotal;
        }
        else if (last is { } onlyIncrement)
        {
            usage = onlyIncrement.AsUsage();
            nextTotals = state.PreviousTotals;
        }
        else
        {
            return [];
        }

        if (usage.TotalTokens <= 0)
        {
            return [];
        }
        state.PreviousTotals = nextTotals;

        var timestamp = ParseTimestamp(StringProperty(entry, "timestamp")) ?? DateTimeOffset.UtcNow;
        var sessionId = state.SessionIdFromMeta ?? fallbackSessionId;
        var scopeId = state.ForkParentId ?? sessionId;
        var provider = state.Provider ?? "unknown";
        var model = NonEmpty(StringProperty(info, "model")) ?? state.CurrentModel ?? "unknown";
        var key = DeduplicationKey(timestamp, usage, total, scopeId, provider, model);
        return [new UsageEvent(timestamp, usage, sessionId, key)];
    }

    private static bool ShouldSkipInherited(UsageTotals? total, TokenParserState state)
    {
        if (total is { } totals && state.InheritedReportedTotal is { } reported &&
            totals.ReportedTotal <= reported)
        {
            return true;
        }
        return total is { } current && state.InheritedBaseline is { } baseline &&
            current.IsWithin(baseline);
    }

    private static bool ChildTurnStartsOwnSession(TokenParserState state, string? turnId)
    {
        if (state.ReplaySessionId is null)
        {
            return true;
        }
        var childPrefix = UuidV7MillisecondPrefix(state.ChildSessionId);
        var turnPrefix = UuidV7MillisecondPrefix(turnId);
        if (childPrefix is null || turnPrefix is null)
        {
            return false;
        }
        var comparison = string.CompareOrdinal(turnPrefix, childPrefix);
        if (comparison > 0)
        {
            return true;
        }
        if (comparison < 0)
        {
            return false;
        }
        return state.ChildIsUserFork || state.ChildTaskStartedTurnIds.Contains(turnId!);
    }

    private static string? UuidV7MillisecondPrefix(string? id)
    {
        if (id is null)
        {
            return null;
        }
        var parts = id.Split('-');
        if (parts.Length != 5 || parts[0].Length != 8 || parts[1].Length != 4 ||
            parts[2].Length != 4 || parts[2][0] != '7')
        {
            return null;
        }
        var prefix = (parts[0] + parts[1]).ToLowerInvariant();
        return prefix.All(Uri.IsHexDigit) ? prefix : null;
    }

    private static string DeduplicationKey(
        DateTimeOffset timestamp,
        TokenUsage usage,
        UsageTotals? total,
        string scopeId,
        string provider,
        string model)
    {
        var time = timestamp.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);
        return total is { } totals
            ? string.Join(':', "codex", "total", scopeId, provider, model, time,
                totals.Input, totals.Output, totals.Cached, totals.Reasoning,
                totals.ReportedTotal)
            : string.Join(':', "codex", "event", scopeId, provider, model, time,
                usage.InputTokens, usage.CachedInputTokens, usage.OutputTokens,
                usage.ReasoningOutputTokens);
    }

    private static DateTimeOffset? ParseTimestamp(string? value) =>
        DateTimeOffset.TryParse(
            value,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
            out var date)
            ? date
            : null;

    private static TokenUsage? UsageProperty(JsonElement parent, string name)
    {
        if (!ObjectProperty(parent, name, out var usage))
        {
            return null;
        }
        return new TokenUsage(
            LongProperty(usage, "input_tokens"),
            LongProperty(usage, "cached_input_tokens"),
            LongProperty(usage, "output_tokens"),
            LongProperty(usage, "reasoning_output_tokens"),
            NullableLongProperty(usage, "total_tokens"));
    }

    private static string? ResolvedModel(JsonElement payload)
    {
        string? slug = null;
        if (ObjectProperty(payload, "model_info", out var modelInfo))
        {
            slug = NonEmpty(StringProperty(modelInfo, "slug"));
        }
        string? infoModel = null;
        if (ObjectProperty(payload, "info", out var info))
        {
            infoModel = NonEmpty(StringProperty(info, "model"));
        }
        return slug ?? NonEmpty(StringProperty(payload, "model")) ??
            NonEmpty(StringProperty(payload, "model_name")) ?? infoModel;
    }

    private static string? ResolvedForkParentId(JsonElement payload)
    {
        var direct = NonEmpty(StringProperty(payload, "forked_from_id"));
        if (direct is not null)
        {
            return direct;
        }
        if (!ObjectProperty(payload, "source", out var source) ||
            !ObjectProperty(source, "subagent", out var subagent) ||
            !ObjectProperty(subagent, "thread_spawn", out var spawn))
        {
            return null;
        }
        return NonEmpty(StringProperty(spawn, "parent_thread_id"));
    }

    private static bool ObjectProperty(JsonElement parent, string name, out JsonElement value)
    {
        if (parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out value) &&
            value.ValueKind == JsonValueKind.Object)
        {
            return true;
        }
        value = default;
        return false;
    }

    private static string? StringProperty(JsonElement parent, string name) =>
        parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out var value) &&
        value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static long LongProperty(JsonElement parent, string name) =>
        NullableLongProperty(parent, name) ?? 0;

    private static long? NullableLongProperty(JsonElement parent, string name) =>
        parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out var value) &&
        value.TryGetInt64(out var number)
            ? number
            : null;

    private static string? NonEmpty(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}
