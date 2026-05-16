from local_llm.contracts import RespondRequest


def test_respond_request_contract():
    req = RespondRequest(workflow_id="default_rag_answer", input="hello")
    assert req.workflow_id == "default_rag_answer"
