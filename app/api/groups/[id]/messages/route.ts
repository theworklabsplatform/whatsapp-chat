import { NextRequest, NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';

/**
 * GET - Get all broadcast messages for a group
 */
export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  try {
    const supabase = await createClient();
    
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) {
      return NextResponse.json(
        { error: 'Unauthorized' },
        { status: 401 }
      );
    }

    const { id: groupId } = await params;

    // Verify group ownership
    const { data: group } = await supabase
      .from('chat_groups')
      .select('id')
      .eq('id', groupId)
      .eq('owner_id', user.id)
      .single();

    if (!group) {
      return NextResponse.json(
        { error: 'Group not found or unauthorized' },
        { status: 404 }
      );
    }

    // Broadcast messages are stored as outgoing: sender_id = user.id, receiver_id = phone number.
    // Fetch all messages sent by this user, then filter by broadcast_group_id in media_data.
    const { data: messages, error: messagesError } = await supabase
      .from('messages')
      .select('*')
      .eq('sender_id', user.id)
      .eq('is_sent_by_me', true)
      .order('timestamp', { ascending: true });

    if (messagesError) {
      console.error('Error fetching broadcast messages:', messagesError);
      return NextResponse.json(
        { error: 'Failed to fetch messages', details: messagesError.message },
        { status: 500 }
      );
    }

    // Filter messages that belong to this broadcast group
    const broadcastMessages = messages?.filter(msg => {
      if (!msg.media_data) return false;
      try {
        const mediaData = typeof msg.media_data === 'string'
          ? JSON.parse(msg.media_data)
          : msg.media_data;
        return mediaData.broadcast_group_id === groupId;
      } catch {
        return false;
      }
    }) || [];

    // Deduplicate: the same broadcast produces one DB row per recipient.
    // Use content + timestamp as the deduplication key so we show one entry per send.
    const uniqueBroadcasts = new Map<string, typeof broadcastMessages[0]>();
    broadcastMessages.forEach(msg => {
      const key = `${msg.timestamp}__${msg.content}`;
      if (!uniqueBroadcasts.has(key)) {
        uniqueBroadcasts.set(key, msg);
      }
    });

    // Format for display — all are sent by the current user
    const formattedMessages = Array.from(uniqueBroadcasts.values()).map(msg => ({
      id: msg.id,
      sender_id: msg.sender_id,
      receiver_id: msg.receiver_id,
      content: msg.content,
      timestamp: msg.timestamp,
      is_sent_by_me: true,
      message_type: msg.message_type,
      media_data: msg.media_data,
      is_read: true,
    }));

    return NextResponse.json({
      success: true,
      messages: formattedMessages,
      count: formattedMessages.length
    });

  } catch (error) {
    console.error('Error in get broadcast messages API:', error);
    return NextResponse.json(
      { error: 'Internal server error' },
      { status: 500 }
    );
  }
}

