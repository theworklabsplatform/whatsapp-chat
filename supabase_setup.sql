-- =============================================================
-- WHATSAPP SAAS PLATFORM — FULL SETUP
-- Run this in Supabase SQL Editor to set up tables, RLS, indexes,
-- views, and RPC functions for full multi-tenant isolation.
-- =============================================================


-- -------------------------------------------------------------
-- 1. USER_CONTACTS TABLE — schema only
-- Created first because the users RLS policy (section 3)
-- references this table in an EXISTS check.
-- -------------------------------------------------------------

CREATE TABLE IF NOT EXISTS user_contacts (
  owner_id   UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  contact_id TEXT        NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (owner_id, contact_id)
);


-- -------------------------------------------------------------
-- 2. MESSAGES TABLE — RLS
-- -------------------------------------------------------------

ALTER TABLE messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_own_messages"         ON messages;
DROP POLICY IF EXISTS "users_insert_own_messages"  ON messages;
DROP POLICY IF EXISTS "users_update_own_messages"  ON messages;

-- Only see messages you sent or received
CREATE POLICY "users_own_messages" ON messages
  FOR SELECT USING (
    sender_id   = auth.uid()::text OR
    receiver_id = auth.uid()::text
  );

-- Only insert messages as yourself (webhooks use service role — bypass)
CREATE POLICY "users_insert_own_messages" ON messages
  FOR INSERT WITH CHECK (
    sender_id = auth.uid()::text
  );

-- Only update messages in your own conversations
CREATE POLICY "users_update_own_messages" ON messages
  FOR UPDATE USING (
    sender_id   = auth.uid()::text OR
    receiver_id = auth.uid()::text
  );


-- -------------------------------------------------------------
-- 3. USERS (CONTACTS) TABLE — RLS
-- Allow reading contacts you have messaged OR explicitly added.
-- This prevents cross-tenant contact enumeration while still
-- allowing newly added contacts (no messages yet) to be visible.
-- -------------------------------------------------------------

ALTER TABLE users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "authenticated_read_users"  ON users;
DROP POLICY IF EXISTS "users_manage_own_record"   ON users;
DROP POLICY IF EXISTS "users_update_own_record"   ON users;
DROP POLICY IF EXISTS "users_read_own_contacts"   ON users;

CREATE POLICY "users_read_own_contacts" ON users
  FOR SELECT USING (
    -- The contact is the current auth user (business owner sees their own row)
    id = auth.uid()::text
    OR
    -- The contact appears in the user's message history
    EXISTS (
      SELECT 1 FROM messages m
      WHERE
        (m.sender_id   = auth.uid()::text AND m.receiver_id = users.id) OR
        (m.receiver_id = auth.uid()::text AND m.sender_id   = users.id)
    )
    OR
    -- The contact was explicitly added (visible before first message)
    EXISTS (
      SELECT 1 FROM user_contacts uc
      WHERE uc.owner_id = auth.uid() AND uc.contact_id = users.id
    )
  );

-- Contacts are created/updated by webhooks (service role) and by send-message.
-- Allow authenticated users to upsert their own contact row.
CREATE POLICY "users_manage_own_record" ON users
  FOR INSERT WITH CHECK (id = auth.uid()::text);

CREATE POLICY "users_update_own_record" ON users
  FOR UPDATE USING (id = auth.uid()::text);


-- -------------------------------------------------------------
-- 4. USER_SETTINGS TABLE — RLS
-- Each user can only read/write their own settings row.
-- Webhooks use service role (bypasses RLS).
-- -------------------------------------------------------------

ALTER TABLE user_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_own_settings_select" ON user_settings;
DROP POLICY IF EXISTS "users_own_settings_insert" ON user_settings;
DROP POLICY IF EXISTS "users_own_settings_update" ON user_settings;

CREATE POLICY "users_own_settings_select" ON user_settings
  FOR SELECT USING (id = auth.uid());

CREATE POLICY "users_own_settings_insert" ON user_settings
  FOR INSERT WITH CHECK (id = auth.uid());

CREATE POLICY "users_own_settings_update" ON user_settings
  FOR UPDATE USING (id = auth.uid());


-- -------------------------------------------------------------
-- 5. CHAT_GROUPS TABLE — RLS
-- Each business owner only sees and manages their own groups.
-- -------------------------------------------------------------

ALTER TABLE chat_groups ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_own_groups_select" ON chat_groups;
DROP POLICY IF EXISTS "users_own_groups_insert" ON chat_groups;
DROP POLICY IF EXISTS "users_own_groups_update" ON chat_groups;
DROP POLICY IF EXISTS "users_own_groups_delete" ON chat_groups;

CREATE POLICY "users_own_groups_select" ON chat_groups
  FOR SELECT USING (owner_id = auth.uid());

CREATE POLICY "users_own_groups_insert" ON chat_groups
  FOR INSERT WITH CHECK (owner_id = auth.uid());

CREATE POLICY "users_own_groups_update" ON chat_groups
  FOR UPDATE USING (owner_id = auth.uid());

CREATE POLICY "users_own_groups_delete" ON chat_groups
  FOR DELETE USING (owner_id = auth.uid());


-- -------------------------------------------------------------
-- 6. GROUP_MEMBERS TABLE — RLS
-- Users can only manage members of groups they own.
-- -------------------------------------------------------------

ALTER TABLE group_members ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_own_group_members_select" ON group_members;
DROP POLICY IF EXISTS "users_own_group_members_insert" ON group_members;
DROP POLICY IF EXISTS "users_own_group_members_delete" ON group_members;

CREATE POLICY "users_own_group_members_select" ON group_members
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM chat_groups g
      WHERE g.id = group_members.group_id
        AND g.owner_id = auth.uid()
    )
  );

CREATE POLICY "users_own_group_members_insert" ON group_members
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM chat_groups g
      WHERE g.id = group_members.group_id
        AND g.owner_id = auth.uid()
    )
  );

CREATE POLICY "users_own_group_members_delete" ON group_members
  FOR DELETE USING (
    EXISTS (
      SELECT 1 FROM chat_groups g
      WHERE g.id = group_members.group_id
        AND g.owner_id = auth.uid()
    )
  );


-- -------------------------------------------------------------
-- 7. USER_CONTACTS TABLE — RLS
-- Table created in section 1; RLS added here after all other
-- tables exist (no cross-table dependencies in these policies).
-- -------------------------------------------------------------

ALTER TABLE user_contacts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_contacts_owner_select" ON user_contacts;
DROP POLICY IF EXISTS "user_contacts_owner_insert" ON user_contacts;
DROP POLICY IF EXISTS "user_contacts_owner_delete" ON user_contacts;

CREATE POLICY "user_contacts_owner_select" ON user_contacts
  FOR SELECT USING (owner_id = auth.uid());

CREATE POLICY "user_contacts_owner_insert" ON user_contacts
  FOR INSERT WITH CHECK (owner_id = auth.uid());

CREATE POLICY "user_contacts_owner_delete" ON user_contacts
  FOR DELETE USING (owner_id = auth.uid());


-- -------------------------------------------------------------
-- 8. PERFORMANCE INDEXES
-- -------------------------------------------------------------

-- Conversations: filter by sender or receiver (most common query)
CREATE INDEX IF NOT EXISTS idx_messages_sender_id   ON messages (sender_id);
CREATE INDEX IF NOT EXISTS idx_messages_receiver_id ON messages (receiver_id);

-- Unread badge count query
CREATE INDEX IF NOT EXISTS idx_messages_receiver_unread
  ON messages (receiver_id, is_read)
  WHERE is_read = FALSE;

-- Conversation timestamp ordering
CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages (timestamp DESC);

-- Webhook token lookup (hot path — every incoming message)
CREATE INDEX IF NOT EXISTS idx_user_settings_webhook_token
  ON user_settings (webhook_token)
  WHERE webhook_token IS NOT NULL;

-- Group membership lookup
CREATE INDEX IF NOT EXISTS idx_group_members_group_id ON group_members (group_id);
CREATE INDEX IF NOT EXISTS idx_group_members_user_id  ON group_members (user_id);

-- Explicit contacts lookup
CREATE INDEX IF NOT EXISTS idx_user_contacts_owner_id ON user_contacts (owner_id);


-- -------------------------------------------------------------
-- 9. user_conversations VIEW
-- security_invoker = true so RLS policies are enforced inside
-- the view. Contacts with no messages are included via the
-- user_contacts table (sorted to the bottom of the list).
-- -------------------------------------------------------------

DROP VIEW IF EXISTS user_conversations;

CREATE OR REPLACE VIEW user_conversations
WITH (security_invoker = true)
AS
WITH latest_messages AS (
  SELECT DISTINCT ON (
    CASE
      WHEN sender_id = auth.uid()::text THEN receiver_id
      ELSE sender_id
    END
  )
    CASE
      WHEN sender_id = auth.uid()::text THEN receiver_id
      ELSE sender_id
    END AS partner_id,
    content,
    message_type,
    timestamp AS last_message_time,
    sender_id  AS last_message_sender
  FROM messages
  WHERE sender_id = auth.uid()::text OR receiver_id = auth.uid()::text
  ORDER BY
    CASE
      WHEN sender_id = auth.uid()::text THEN receiver_id
      ELSE sender_id
    END,
    timestamp DESC
),
unread_counts AS (
  SELECT sender_id AS partner_id, COUNT(*) AS unread_count
  FROM messages
  WHERE receiver_id = auth.uid()::text AND is_read = FALSE
  GROUP BY sender_id
),
-- Union of contacts from message history AND explicitly added contacts
all_contacts AS (
  SELECT partner_id AS contact_id FROM latest_messages
  UNION
  SELECT contact_id FROM user_contacts WHERE owner_id = auth.uid()
)
SELECT
  u.id,
  COALESCE(u.custom_name, u.whatsapp_name, u.name, u.id) AS display_name,
  u.custom_name,
  u.whatsapp_name,
  u.name AS original_name,
  u.last_active,
  COALESCE(uc.unread_count, 0)                           AS unread_count,
  lm.content                                             AS last_message,
  lm.message_type                                        AS last_message_type,
  lm.last_message_time,
  lm.last_message_sender,
  CASE WHEN uc.unread_count > 0 THEN 1 ELSE 0 END       AS has_unread
FROM users u
INNER JOIN all_contacts ac ON u.id = ac.contact_id
LEFT JOIN latest_messages lm ON u.id = lm.partner_id
LEFT JOIN unread_counts uc   ON u.id = uc.partner_id
ORDER BY has_unread DESC, last_message_time DESC NULLS LAST;


-- -------------------------------------------------------------
-- 10. RPC FUNCTIONS
-- -------------------------------------------------------------

-- get_conversation_messages: fetch messages between current user and another user
DROP FUNCTION IF EXISTS public.get_conversation_messages(text) CASCADE;

CREATE OR REPLACE FUNCTION public.get_conversation_messages(other_user_id text)
RETURNS TABLE (
  id           text,
  sender_id    text,
  receiver_id  text,
  content      text,
  "timestamp"  timestamptz,
  is_sent_by_me boolean,
  message_type text,
  media_data   jsonb,
  is_read      boolean
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    m.id::text,
    m.sender_id,
    m.receiver_id::text,
    m.content,
    m.timestamp,
    m.is_sent_by_me,
    m.message_type,
    m.media_data,
    m.is_read
  FROM public.messages m
  WHERE
    (m.sender_id = other_user_id AND m.receiver_id = auth.uid()::text) OR
    (m.sender_id = auth.uid()::text AND m.receiver_id = other_user_id)
  ORDER BY m.timestamp ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_conversation_messages(text) TO authenticated;


-- mark_messages_as_read
DROP FUNCTION IF EXISTS public.mark_messages_as_read(text) CASCADE;

CREATE OR REPLACE FUNCTION public.mark_messages_as_read(conversation_id text)
RETURNS TABLE (updated_count int) AS $$
DECLARE
  v_updated_count int;
BEGIN
  UPDATE public.messages
  SET is_read = true
  WHERE receiver_id = auth.uid()::text
    AND sender_id   = conversation_id
    AND is_read     = false;

  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  RETURN QUERY SELECT v_updated_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.mark_messages_as_read(text) TO authenticated;


-- get_unread_conversations: used by preload in chat page
DROP FUNCTION IF EXISTS public.get_unread_conversations(int) CASCADE;

CREATE OR REPLACE FUNCTION public.get_unread_conversations(limit_count int DEFAULT 10)
RETURNS TABLE (
  conversation_id   text,
  display_name      text,
  unread_count      bigint,
  last_message_time timestamptz
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    m.sender_id                                                     AS conversation_id,
    COALESCE(u.custom_name, u.whatsapp_name, u.name, m.sender_id)  AS display_name,
    COUNT(*)                                                        AS unread_count,
    MAX(m.timestamp)                                                AS last_message_time
  FROM messages m
  LEFT JOIN users u ON u.id = m.sender_id
  WHERE m.receiver_id = auth.uid()::text
    AND m.is_read     = false
  GROUP BY m.sender_id, u.custom_name, u.whatsapp_name, u.name
  ORDER BY last_message_time DESC
  LIMIT limit_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_unread_conversations(int) TO authenticated;


-- get_user_groups_with_counts: used by groups list
DROP FUNCTION IF EXISTS public.get_user_groups_with_counts(uuid) CASCADE;

CREATE OR REPLACE FUNCTION public.get_user_groups_with_counts(user_uuid uuid)
RETURNS TABLE (
  id           uuid,
  name         text,
  description  text,
  owner_id     uuid,
  created_at   timestamptz,
  member_count bigint
) AS $$
BEGIN
  -- Enforce that callers can only query their own groups
  IF user_uuid != auth.uid() THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  RETURN QUERY
  SELECT
    g.id,
    g.name,
    g.description,
    g.owner_id,
    g.created_at,
    COUNT(gm.user_id) AS member_count
  FROM chat_groups g
  LEFT JOIN group_members gm ON gm.group_id = g.id
  WHERE g.owner_id = user_uuid
  GROUP BY g.id, g.name, g.description, g.owner_id, g.created_at
  ORDER BY g.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_user_groups_with_counts(uuid) TO authenticated;


-- get_group_members_with_details: used by /api/groups/[id]/members GET
DROP FUNCTION IF EXISTS public.get_group_members_with_details(uuid) CASCADE;

CREATE OR REPLACE FUNCTION public.get_group_members_with_details(p_group_id uuid)
RETURNS TABLE (
  user_id       text,
  name          text,
  custom_name   text,
  whatsapp_name text,
  display_name  text,
  last_active   timestamptz,
  added_at      timestamptz
) AS $$
BEGIN
  -- Verify caller owns the group
  IF NOT EXISTS (
    SELECT 1 FROM chat_groups g
    WHERE g.id = p_group_id AND g.owner_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  RETURN QUERY
  SELECT
    gm.user_id,
    u.name,
    u.custom_name,
    u.whatsapp_name,
    COALESCE(u.custom_name, u.whatsapp_name, u.name, gm.user_id) AS display_name,
    u.last_active,
    NULL::timestamptz AS added_at
  FROM group_members gm
  LEFT JOIN users u ON u.id = gm.user_id
  WHERE gm.group_id = p_group_id
  ORDER BY gm.user_id ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.get_group_members_with_details(uuid) TO authenticated;


-- create_or_get_user: upsert a contact and record it in user_contacts
-- so the contact appears in the chat list before any message is sent.
DROP FUNCTION IF EXISTS public.create_or_get_user(text, text, text) CASCADE;
DROP FUNCTION IF EXISTS public.create_or_get_user(text, text) CASCADE;

CREATE OR REPLACE FUNCTION public.create_or_get_user(
  phone_number  text,
  user_name     text DEFAULT NULL
)
RETURNS TABLE (
  id            text,
  name          text,
  custom_name   text,
  whatsapp_name text,
  last_active   timestamptz,
  is_new        boolean
) AS $$
DECLARE
  v_is_new boolean;
BEGIN
  -- Check whether the contact already exists
  -- (avoids ON CONFLICT (id) which is ambiguous with the 'id' output variable)
  SELECT NOT EXISTS(
    SELECT 1 FROM public.users u WHERE u.id = phone_number
  ) INTO v_is_new;

  IF v_is_new THEN
    INSERT INTO public.users (id, name, custom_name)
    VALUES (phone_number, COALESCE(user_name, phone_number), user_name);
  ELSE
    -- Only update custom_name if a non-null value was supplied
    UPDATE public.users u
    SET custom_name = COALESCE(user_name, u.custom_name)
    WHERE u.id = phone_number;
  END IF;

  -- Track this contact for the calling business owner
  INSERT INTO public.user_contacts (owner_id, contact_id)
  VALUES (auth.uid(), phone_number)
  ON CONFLICT (owner_id, contact_id) DO NOTHING;

  -- Return the full contact record
  RETURN QUERY
  SELECT
    u.id,
    COALESCE(u.custom_name, u.whatsapp_name, u.name, u.id) AS name,
    u.custom_name,
    u.whatsapp_name,
    u.last_active,
    v_is_new AS is_new
  FROM public.users u
  WHERE u.id = phone_number;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION public.create_or_get_user(text, text) TO authenticated;


-- =============================================================
-- DONE.  Each tenant is now fully isolated:
--   • messages       — only your sent/received messages
--   • users          — only contacts you have messaged or added
--   • user_contacts  — only your own explicitly added contacts
--   • user_settings  — only your own settings
--   • chat_groups    — only your own groups
--   • group_members  — only members of your groups
-- =============================================================
