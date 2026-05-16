from local_llm.store.sqlite_store import make_fts_query


def test_make_fts_query():
    assert '"provider"' in make_fts_query("provider contract")
