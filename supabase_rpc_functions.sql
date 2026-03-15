-- Create the missing RPC functions for WhatsApp Chat

-- Drop existing functions first (if they exist)
DROP FUNCTION IF EXISTS public.get_conversation_messages(text) CASCADE;
DROP FUNCTION IF EXISTS public.get_unread_conversations(int) CASCADE;
DROP FUNCTION IF EXISTS public.get_user_groups_with_counts(uuid) CASCADE;
DROP FUNCTION IF EXISTS public.create_or_get_user(text, text, text) CASCADE;
DROP FUNCTION IF EXISTS public.mark_messages_as_read(text) CASCADE;
DROP FUNCTION IF EXISTS public.get_group_members_with_details(uuid) CASCADE;

-- 1. get_conversation_messages: Fetch messages between current user and another user
CREATE OR REPLACE FUNCTION public.get_conversation_messages(other_user_id text)
RETURNS TABLE (
  id text,
  sender_id text,
  receiver_id text,
  content text,
  "timestamp" timestamptz,
  is_sent_by_me boolean,
  message_type text,
  media_data jsonb,
  is_read boolean
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    m.id::text,
    m.sender_id,
    m.receiver_id::text,
    m.content,
    m.timestamp,
    -- Return the stored is_sent_by_me field directly (true = I sent it, false = I received it)
    m.is_sent_by_me,
    m.message_type,
    m.media_data,
    m.is_read
  FROM public.messages m
  WHERE 
    (m.sender_id = other_user_id AND m.receiver_id::uuid = auth.uid()) OR
    (m.sender_id = other_user_id AND m.is_sent_by_me = true)
  ORDER BY m.timestamp ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. get_unread_conversations: Get top unread conversations
CREATE OR REPLACE FUNCTION public.get_unread_conversations(limit_count int DEFAULT 10)
RETURNS TABLE (
  conversation_id text,
  display_name text,
  unread_count int,
  "last_message_time" timestamptz
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    CASE 
      WHEN m.sender_id = auth.uid()::text THEN m.receiver_id
      ELSE m.sender_id
    END as conversation_id,
    COALESCE(u.custom_name, u.whatsapp_name, u.name) as display_name,
    COUNT(*) FILTER (WHERE m.is_read = false AND m.receiver_id = auth.uid()::text)::int as unread_count,
    MAX(m.timestamp) as "last_message_time"
  FROM public.messages m
  LEFT JOIN public.users u ON (
    CASE 
      WHEN m.sender_id = auth.uid()::text THEN u.id = m.receiver_id
      ELSE u.id = m.sender_id
    END
  )
  WHERE (m.sender_id = auth.uid()::text OR m.receiver_id = auth.uid()::text)
  GROUP BY conversation_id, display_name
  HAVING COUNT(*) FILTER (WHERE m.is_read = false AND m.receiver_id = auth.uid()::text) > 0
  ORDER BY "last_message_time" DESC
  LIMIT limit_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. get_user_groups_with_counts: Get groups with member counts
CREATE OR REPLACE FUNCTION public.get_user_groups_with_counts(user_uuid uuid)
RETURNS TABLE (
  id uuid,
  owner_id uuid,
  name text,
  description text,
  created_at timestamptz,
  member_count int
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    g.id,
    g.owner_id,
    g.name,
    g.description,
    g.created_at,
    COUNT(gm.user_id)::int as member_count
  FROM public.chat_groups g
  LEFT JOIN public.group_members gm ON g.id = gm.group_id
  WHERE g.owner_id = user_uuid
  GROUP BY g.id, g.owner_id, g.name, g.description, g.created_at
  ORDER BY g.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. create_or_get_user: Create user if not exists or return existing
CREATE OR REPLACE FUNCTION public.create_or_get_user(
  user_id text,
  user_name text DEFAULT NULL,
  user_phone text DEFAULT NULL
)
RETURNS TABLE (
  id text,
  name text,
  created_at timestamptz
) AS $$
BEGIN
  INSERT INTO public.users (id, name)
  VALUES (user_id, user_name)
  ON CONFLICT (id) DO UPDATE SET
    name = COALESCE(EXCLUDED.name, users.name)
  RETURNING users.id, users.name, users.created_at
  INTO id, name, created_at;
  
  RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. mark_messages_as_read: Mark messages as read
CREATE OR REPLACE FUNCTION public.mark_messages_as_read(
  conversation_id text
)
RETURNS TABLE (
  updated_count int
) AS $$
DECLARE
  v_updated_count int;
BEGIN
  UPDATE public.messages
  SET is_read = true
  WHERE receiver_id = auth.uid()::text AND sender_id = conversation_id AND is_read = false;
  
  GET DIAGNOSTICS v_updated_count = ROW_COUNT;
  
  RETURN QUERY SELECT v_updated_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. get_group_members_with_details: Get group members with details
CREATE OR REPLACE FUNCTION public.get_group_members_with_details(p_group_id uuid)
RETURNS TABLE (
  user_id text,
  name text,
  custom_name text,
  whatsapp_name text
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    u.id::text,
    u.name,
    u.custom_name,
    u.whatsapp_name
  FROM public.users u
  JOIN public.group_members gm ON u.id::text = gm.user_id::text
  WHERE gm.group_id = p_group_id
  ORDER BY u.name ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute permissions to authenticated users
GRANT EXECUTE ON FUNCTION public.get_conversation_messages(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_unread_conversations(int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_user_groups_with_counts(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_or_get_user(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_messages_as_read(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_group_members_with_details(uuid) TO authenticated;
