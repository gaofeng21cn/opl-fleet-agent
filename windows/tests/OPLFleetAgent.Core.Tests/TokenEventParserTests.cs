using OPLFleetAgent.Core;

namespace OPLFleetAgent.Core.Tests;

public sealed class TokenEventParserTests
{
    [Fact]
    public void UsesLastUsageWithoutDoubleCountingSubsets()
    {
        var result = TokenEventParser.Parse(
        [
            """{"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{"id":"session-a","model_provider":"test-provider"}}""",
            """{"timestamp":"2026-07-14T00:00:01Z","type":"turn_context","payload":{"model":"gpt-test"}}""",
            """{"timestamp":"2026-07-14T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":10,"total_tokens":120},"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"reasoning_output_tokens":10,"total_tokens":120}}}}""",
        ], new TokenParserState(), "fallback");

        var usage = Assert.Single(result.Events).Usage;
        Assert.Equal(120, usage.TotalTokens);
        Assert.Equal(80, usage.CachedInputTokens);
        Assert.Equal(10, usage.ReasoningOutputTokens);
        Assert.Equal(120, usage.InputTokens + usage.OutputTokens);
    }

    [Fact]
    public void SuppressesRepeatedCumulativeSnapshot()
    {
        const string token =
            """{"timestamp":"2026-07-14T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}""";
        var result = TokenEventParser.Parse(
        [
            """{"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{"id":"session-a","model_provider":"test-provider"}}""",
            token,
            token,
        ], new TokenParserState(), "fallback");

        Assert.Single(result.Events);
    }

    [Fact]
    public void SkipsForkReplayUntilOwnUuidV7Turn()
    {
        const string childId = "019f5e41-117d-7000-8000-000000000001";
        const string childTurnId = "019f5e41-117e-7000-8000-000000000001";
        var result = TokenEventParser.Parse(
        [
            With("""{"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{"id":"$CHILD","forked_from_id":"parent","thread_source":"subagent","model_provider":"test-provider"}}""", "$CHILD", childId),
            """{"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{"id":"parent","model_provider":"test-provider"}}""",
            """{"timestamp":"2026-07-14T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}""",
            With("""{"timestamp":"2026-07-14T00:00:02Z","type":"event_msg","payload":{"type":"task_started","turn_id":"$TURN"}}""", "$TURN", childTurnId),
            With("""{"timestamp":"2026-07-14T00:00:03Z","type":"turn_context","payload":{"turn_id":"$TURN","model":"gpt-test"}}""", "$TURN", childTurnId),
            """{"timestamp":"2026-07-14T00:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}""",
            """{"timestamp":"2026-07-14T00:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"output_tokens":22,"total_tokens":142},"last_token_usage":{"input_tokens":20,"output_tokens":2,"total_tokens":22}}}}""",
        ], new TokenParserState(), childId);

        var usageEvent = Assert.Single(result.Events);
        Assert.Equal(22, usageEvent.Usage.TotalTokens);
        Assert.Equal(childId, usageEvent.SessionId);
    }

    [Fact]
    public void KeepsSkippingLegacyReplayTurnIds()
    {
        const string childId = "019f602b-1e2f-7d60-ac59-83fa4dd52c92";
        const string childTurnId = "019f602b-4e8a-7360-ad43-2e65035ba716";
        const string legacyTurnId = "49b1eb54-d964-4272-8c71-01c9eed13679";
        var result = TokenEventParser.Parse(
        [
            With("""{"timestamp":"2026-07-14T10:27:58Z","type":"session_meta","payload":{"id":"$CHILD","forked_from_id":"parent","thread_source":"subagent","model_provider":"test-provider"}}""", "$CHILD", childId),
            """{"timestamp":"2026-07-14T10:27:58Z","type":"session_meta","payload":{"id":"parent","model_provider":"test-provider"}}""",
            With("""{"timestamp":"2026-07-14T10:27:58Z","type":"event_msg","payload":{"type":"task_started","turn_id":"$TURN"}}""", "$TURN", legacyTurnId),
            With("""{"timestamp":"2026-07-14T10:27:58Z","type":"turn_context","payload":{"turn_id":"$TURN","model":"gpt-test"}}""", "$TURN", legacyTurnId),
            """{"timestamp":"2026-07-14T10:27:58Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}""",
            With("""{"timestamp":"2026-07-14T10:27:59Z","type":"event_msg","payload":{"type":"task_started","turn_id":"$TURN"}}""", "$TURN", childTurnId),
            With("""{"timestamp":"2026-07-14T10:28:00Z","type":"turn_context","payload":{"turn_id":"$TURN","model":"gpt-test"}}""", "$TURN", childTurnId),
            """{"timestamp":"2026-07-14T10:28:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"output_tokens":22,"total_tokens":142},"last_token_usage":{"input_tokens":20,"output_tokens":2,"total_tokens":22}}}}""",
        ], new TokenParserState(), childId);

        Assert.Equal(22, Assert.Single(result.Events).Usage.TotalTokens);
    }

    [Fact]
    public void CrossFileReplayUsesStableIdentity()
    {
        const string token =
            """{"timestamp":"2026-07-14T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}}""";
        var parent = TokenEventParser.Parse(
        [
            """{"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{"id":"parent","model_provider":"test-provider"}}""",
            """{"timestamp":"2026-07-14T00:00:01Z","type":"turn_context","payload":{"model":"gpt-test"}}""",
            token,
        ], new TokenParserState(), "parent");
        var child = TokenEventParser.Parse(
        [
            """{"timestamp":"2026-07-14T00:00:00Z","type":"session_meta","payload":{"id":"child","forked_from_id":"parent","model_provider":"test-provider"}}""",
            """{"timestamp":"2026-07-14T00:00:01Z","type":"turn_context","payload":{"model":"gpt-test"}}""",
            token,
        ], new TokenParserState(), "child");

        Assert.Equal(
            Assert.Single(parent.Events).DeduplicationKey,
            Assert.Single(child.Events).DeduplicationKey);
    }

    private static string With(string value, string marker, string replacement) =>
        value.Replace(marker, replacement, StringComparison.Ordinal);
}
