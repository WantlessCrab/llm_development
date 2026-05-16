from local_llm.corpus.chunker import chunk_text


def test_chunk_text_basic():
    chunks = chunk_text("abc\n\n" * 1000, target_chars=500, overlap_chars=50)
    assert chunks
    assert chunks[0].ordinal == 0
    assert chunks[0].text_hash
