"""Tenant isolation and identity propagation integration tests for Praxis proxy behind OGX.

Tests multi-tenant and cross-user isolation across OpenAI resource APIs:
- Files API (/v1/files)
- Vector Stores API (/v1/vector_stores)
- Vector Store File Attachments (/v1/vector_stores/{vs_id}/files)
"""


def test_files_cross_user_isolation(tenant_a_client, tenant_a_user_2_client):
    """User A creates a file via Praxis; User A2 in the same tenant cannot access or delete it."""
    # 1. User A uploads file
    upload_res = tenant_a_client.upload_file(
        filename="test_user_a.txt",
        content=b"Hello from User A in Tenant A",
    )
    assert upload_res.status_code in (200, 201), f"Upload failed: {upload_res.text}"
    file_id = upload_res.json().get("id")
    assert file_id is not None

    try:
        # 2. User A2 (same tenant, different user) attempts to read User A's file
        read_res = tenant_a_user_2_client.get(f"/files/{file_id}")
        assert read_res.status_code in (403, 404), (
            f"User A2 accessed User A's file unexpectedly: status {read_res.status_code}"
        )

        # 3. User A2 attempts to delete User A's file
        del_res = tenant_a_user_2_client.delete(f"/files/{file_id}")
        assert del_res.status_code in (403, 404), (
            f"User A2 deleted User A's file unexpectedly: status {del_res.status_code}"
        )

        # 4. Owner (User A) can retrieve metadata
        owner_read_res = tenant_a_client.get(f"/files/{file_id}")
        assert owner_read_res.status_code == 200, (
            f"Owner failed to read file: {owner_read_res.text}"
        )
    finally:
        # Cleanup: Owner deletes file
        tenant_a_client.delete(f"/files/{file_id}")


def test_files_cross_tenant_isolation(tenant_a_client, tenant_b_client):
    """Tenant A creates a file via Praxis; Tenant B cannot list, access, or delete it."""
    # 1. Tenant A uploads file
    upload_res = tenant_a_client.upload_file(
        filename="tenant_a_secret.txt",
        content=b"Confidential Tenant A Data",
    )
    assert upload_res.status_code in (200, 201), f"Upload failed: {upload_res.text}"
    file_id = upload_res.json().get("id")
    assert file_id is not None

    try:
        # 2. Tenant B lists files - file_id should not be present
        list_res = tenant_b_client.get("/files")
        if list_res.status_code == 200:
            files_data = list_res.json().get("data", [])
            file_ids = [f.get("id") for f in files_data]
            assert file_id not in file_ids, (
                f"File {file_id} leaked into Tenant B list response"
            )

        # 3. Tenant B attempts direct access
        read_res = tenant_b_client.get(f"/files/{file_id}")
        assert read_res.status_code in (403, 404), (
            f"Tenant B accessed Tenant A file: status {read_res.status_code}"
        )

        # 4. Tenant B attempts delete
        del_res = tenant_b_client.delete(f"/files/{file_id}")
        assert del_res.status_code in (403, 404), (
            f"Tenant B deleted Tenant A file: status {del_res.status_code}"
        )
    finally:
        # Cleanup
        tenant_a_client.delete(f"/files/{file_id}")


def test_vector_stores_cross_user_isolation(tenant_a_client, tenant_a_user_2_client):
    """User A creates a vector store via Praxis; User A2 in same tenant cannot see or modify it."""
    # 1. User A creates vector store
    create_res = tenant_a_client.post("/vector_stores", json={"name": "user-a-store"})
    assert create_res.status_code in (200, 201), (
        f"Create vector store failed: {create_res.text}"
    )
    vs_id = create_res.json().get("id")
    assert vs_id is not None

    try:
        # 2. User A2 lists vector stores
        list_res = tenant_a_user_2_client.get("/vector_stores")
        if list_res.status_code == 200:
            stores = list_res.json().get("data", [])
            store_ids = [s.get("id") for s in stores]
            assert vs_id not in store_ids, (
                f"Vector store {vs_id} leaked to User A2 list"
            )

        # 3. User A2 attempts direct retrieve
        read_res = tenant_a_user_2_client.get(f"/vector_stores/{vs_id}")
        assert read_res.status_code in (403, 404), (
            f"User A2 accessed User A's vector store: status {read_res.status_code}"
        )

        # 4. User A2 attempts delete
        del_res = tenant_a_user_2_client.delete(f"/vector_stores/{vs_id}")
        assert del_res.status_code in (403, 404), (
            f"User A2 deleted User A's vector store: status {del_res.status_code}"
        )
    finally:
        # Cleanup
        tenant_a_client.delete(f"/vector_stores/{vs_id}")


def test_vector_stores_cross_tenant_isolation(tenant_a_client, tenant_b_client):
    """Tenant A creates a vector store; Tenant B cannot view or attach files to it."""
    # 1. Tenant A creates vector store
    create_res = tenant_a_client.post("/vector_stores", json={"name": "tenant-a-store"})
    assert create_res.status_code in (200, 201), (
        f"Create vector store failed: {create_res.text}"
    )
    vs_id = create_res.json().get("id")
    assert vs_id is not None

    # Tenant B uploads a file to test cross-tenant attachment
    file_b_res = tenant_b_client.upload_file(
        filename="tenant_b_doc.txt",
        content=b"Tenant B File Content",
    )
    assert file_b_res.status_code in (200, 201)
    file_b_id = file_b_res.json().get("id")

    try:
        # 2. Tenant B lists vector stores
        list_res = tenant_b_client.get("/vector_stores")
        if list_res.status_code == 200:
            stores = list_res.json().get("data", [])
            store_ids = [s.get("id") for s in stores]
            assert vs_id not in store_ids, (
                f"Vector store {vs_id} leaked to Tenant B list"
            )

        # 3. Tenant B attempts to attach their file to Tenant A's vector store
        attach_res = tenant_b_client.post(
            f"/vector_stores/{vs_id}/files",
            json={"file_id": file_b_id},
        )
        assert attach_res.status_code in (403, 404), (
            f"Tenant B attached file to Tenant A vector store: status {attach_res.status_code}"
        )

        # 4. Tenant B attempts direct lookup
        read_res = tenant_b_client.get(f"/vector_stores/{vs_id}")
        assert read_res.status_code in (403, 404)
    finally:
        # Cleanup
        tenant_b_client.delete(f"/files/{file_b_id}")
        tenant_a_client.delete(f"/vector_stores/{vs_id}")


def test_full_resource_attachment_lifecycle(tenant_a_client):
    """Upload file -> create vector store -> attach file -> detach file -> cleanup via Praxis."""
    # 1. Upload file
    upload_res = tenant_a_client.upload_file(
        filename="lifecycle_doc.txt",
        content=b"Full Lifecycle Test Content",
    )
    assert upload_res.status_code in (200, 201)
    file_id = upload_res.json().get("id")

    # 2. Create vector store
    vs_res = tenant_a_client.post("/vector_stores", json={"name": "lifecycle-store"})
    assert vs_res.status_code in (200, 201)
    vs_id = vs_res.json().get("id")

    try:
        # 3. Attach file to vector store
        attach_res = tenant_a_client.post(
            f"/vector_stores/{vs_id}/files",
            json={"file_id": file_id},
        )
        assert attach_res.status_code in (200, 201), (
            f"Attach file failed: {attach_res.text}"
        )

        # 4. List vector store files
        vs_files_res = tenant_a_client.get(f"/vector_stores/{vs_id}/files")
        assert vs_files_res.status_code == 200
        vs_files = vs_files_res.json().get("data", [])
        attached_ids = [f.get("id") for f in vs_files]
        assert file_id in attached_ids, (
            f"File {file_id} not found in vector store attachments"
        )

        # 5. Get file attachment details
        file_detail_res = tenant_a_client.get(f"/vector_stores/{vs_id}/files/{file_id}")
        assert file_detail_res.status_code == 200

        # 6. Detach file from vector store
        detach_res = tenant_a_client.delete(f"/vector_stores/{vs_id}/files/{file_id}")
        assert detach_res.status_code in (200, 204), (
            f"Detach file failed: {detach_res.text}"
        )
    finally:
        # Cleanup
        tenant_a_client.delete(f"/vector_stores/{vs_id}")
        tenant_a_client.delete(f"/files/{file_id}")


def test_unauthenticated_rejection(unauthenticated_client):
    """Requests missing identity headers are rejected with 401 or 403."""
    res_files = unauthenticated_client.get("/files")
    assert res_files.status_code in (401, 403), (
        f"Unauthenticated /files request got status {res_files.status_code}"
    )

    res_vs = unauthenticated_client.get("/vector_stores")
    assert res_vs.status_code in (401, 403), (
        f"Unauthenticated /vector_stores request got status {res_vs.status_code}"
    )
