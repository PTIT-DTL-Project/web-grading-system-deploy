-- AI Assistant Service ERD snapshot (PostgreSQL)
-- Source: ai-assistant-service Flyway migrations V1 through V8.
-- Import this file as PostgreSQL DDL in Visual Paradigm. It contains schema only.
-- Columns such as owner_id, student_id, and submission_id refer to data owned by
-- other services, so this service does not declare foreign keys for them.
-- Likewise, active_task_id, ai_message.run_id, parent_run_id, and
-- through_message_id have no database foreign-key constraints in the migrations.
-- Operational indexes (including partial indexes) are omitted from this ERD DDL.

CREATE TABLE ai_explanations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    submission_id UUID NOT NULL,
    student_id UUID NOT NULL,
    category VARCHAR(30) NOT NULL DEFAULT 'FULL_ANALYSIS',
    diagnosis TEXT NOT NULL,
    suspected_location TEXT,
    actionable_hints JSONB NOT NULL,
    learning_keywords JSONB,
    telemetry_audit JSONB,
    overall_summary TEXT,
    model_name VARCHAR(50),
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    feedback_rating SMALLINT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    deleted_at TIMESTAMP WITH TIME ZONE
);

CREATE TABLE ai_conversation (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL,
    title VARCHAR(255),
    active_task_id UUID,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE TABLE ai_run (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'QUEUED',
    parent_run_id UUID,
    checkpoint_json JSONB,
    version INTEGER NOT NULL DEFAULT 1,
    limits_json JSONB,
    usage_json JSONB,
    error_code VARCHAR(50),
    error_message TEXT,
    started_at TIMESTAMP WITH TIME ZONE,
    finished_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    caller_email VARCHAR(255),
    caller_roles VARCHAR(500),
    next_event_sequence INTEGER NOT NULL DEFAULT 1,
    CONSTRAINT fk_ai_run_conversation FOREIGN KEY (conversation_id)
        REFERENCES ai_conversation(id) ON DELETE CASCADE
);

CREATE TABLE ai_message (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL,
    run_id UUID,
    role VARCHAR(20) NOT NULL,
    content TEXT,
    tool_call_id VARCHAR(100),
    tool_name VARCHAR(100),
    tool_arguments JSONB,
    tool_result JSONB,
    client_message_id VARCHAR(100),
    sequence_no INTEGER NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT fk_ai_message_conversation FOREIGN KEY (conversation_id)
        REFERENCES ai_conversation(id) ON DELETE CASCADE
);

CREATE TABLE ai_task (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL,
    owner_id UUID NOT NULL,
    type VARCHAR(50),
    goal_json JSONB,
    status VARCHAR(30) NOT NULL DEFAULT 'ACTIVE',
    state_json JSONB,
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT fk_ai_task_conversation FOREIGN KEY (conversation_id)
        REFERENCES ai_conversation(id) ON DELETE CASCADE
);

CREATE TABLE ai_conversation_summary (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL,
    through_message_id UUID NOT NULL,
    summary TEXT NOT NULL,
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    role_scope VARCHAR(100) NOT NULL DEFAULT '',
    CONSTRAINT fk_ai_summary_conversation FOREIGN KEY (conversation_id)
        REFERENCES ai_conversation(id) ON DELETE CASCADE
);

CREATE TABLE ai_operation (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id UUID,
    idempotency_key VARCHAR(100) NOT NULL UNIQUE,
    command_type VARCHAR(50) NOT NULL,
    request_hash VARCHAR(64),
    payload_json JSONB NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'PENDING',
    result_ref JSONB,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_check_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT fk_ai_operation_task FOREIGN KEY (task_id)
        REFERENCES ai_task(id) ON DELETE SET NULL
);

CREATE TABLE ai_tool_execution (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id UUID NOT NULL,
    tool_call_id VARCHAR(100),
    tool_name VARCHAR(100) NOT NULL,
    arguments_redacted JSONB,
    result_redacted JSONB,
    status VARCHAR(20) NOT NULL,
    latency_ms INTEGER,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT fk_ai_tool_execution_run FOREIGN KEY (run_id)
        REFERENCES ai_run(id) ON DELETE CASCADE
);

CREATE TABLE ai_pending_action (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id UUID,
    run_id UUID,
    type VARCHAR(30) NOT NULL,
    question_json JSONB,
    options_json JSONB,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    expires_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    result_json JSONB,
    CONSTRAINT fk_ai_pending_action_task FOREIGN KEY (task_id)
        REFERENCES ai_task(id) ON DELETE CASCADE,
    CONSTRAINT fk_ai_pending_action_run FOREIGN KEY (run_id)
        REFERENCES ai_run(id) ON DELETE CASCADE
);

CREATE TABLE ai_run_event (
    id BIGSERIAL PRIMARY KEY,
    run_id UUID NOT NULL,
    sequence INTEGER NOT NULL,
    type VARCHAR(50) NOT NULL,
    payload_json JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    CONSTRAINT fk_ai_run_event_run FOREIGN KEY (run_id)
        REFERENCES ai_run(id) ON DELETE CASCADE,
    CONSTRAINT ux_run_event_run_sequence UNIQUE (run_id, sequence)
);

CREATE TABLE ai_stored_tool_result (
    id UUID PRIMARY KEY,
    run_id UUID NOT NULL,
    conversation_id UUID NOT NULL,
    owner_id UUID NOT NULL,
    role_scope VARCHAR(100) NOT NULL,
    full_result TEXT NOT NULL,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    CONSTRAINT fk_ai_stored_tool_result_run FOREIGN KEY (run_id)
        REFERENCES ai_run(id) ON DELETE CASCADE,
    CONSTRAINT fk_ai_stored_tool_result_conversation FOREIGN KEY (conversation_id)
        REFERENCES ai_conversation(id) ON DELETE CASCADE
);
