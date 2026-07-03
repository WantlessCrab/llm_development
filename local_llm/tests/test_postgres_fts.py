from local_llm.retrieval.postgres_fts import build_postgres_fts_query_shape, \
    build_postgres_fts_or_query


def test_postgres_fts_query_shape_is_not_sql():
    shape = build_postgres_fts_query_shape("provider contract local_llm", top_k=8)
    payload = shape.to_observation_json(candidate_count=2, returned_count=2, included_count=1)
    assert payload["retrieval_method"] == "postgres_fts"
    assert payload["backend"] == "postgresql"
    assert payload["stage_1_query_shape"]["function"] == "websearch_to_tsquery"
    assert "SELECT" not in str(payload).upper()
    assert build_postgres_fts_or_query("provider contract local_llm")