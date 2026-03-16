import { NextRequest, NextResponse } from 'next/server';

import { createClient } from '@/lib/supabase/server';

/**
 * POST handler for sending WhatsApp messages
 * Accepts message data and sends it via WhatsApp Cloud API
 * Now uses user-specific access tokens and phone number IDs
 */
export async function POST(request: NextRequest) {
  try {
    const supabase = await createClient();
    
    // Verify user authentication
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) {
      console.error('Authentication error:', authError);
      return NextResponse.json(
        { error: 'Unauthorized' },
        { status: 401 }
      );
    }

    // Parse request body
    const { to, message, templateName } = await request.json();

    // Validate required parameters
    if (!to || !message) {
      console.error('Missing required parameters:', { to: !!to, message: !!message });
      return NextResponse.json(
        { error: 'Missing required parameters: to, message' },
        { status: 400 }
      );
    }
    
    // Determine if sending as template or text message
    // If templateName provided, send as template; otherwise send as text
    const sendAsTemplate = !!templateName;
    const template = templateName || 'hello_world';

    // Clean and validate phone number format for WhatsApp API
    // WhatsApp expects phone numbers without + prefix, with country code
    const cleanPhoneNumber = to.replace(/\s+/g, '').replace(/[^\d]/g, ''); // Remove all non-digits including +
    
    // Validate phone number format (10-15 digits without + prefix)
    const phoneRegex = /^\d{10,15}$/;
    if (!phoneRegex.test(cleanPhoneNumber)) {
      return NextResponse.json(
        { 
          error: 'Invalid phone number format', 
          message: 'Phone number must contain 10-15 digits (e.g., 918097296453)' 
        },
        { status: 400 }
      );
    }

    // Get user's WhatsApp API credentials
    console.log('Fetching settings for user:', user.id);
    const { data: settings, error: settingsError } = await supabase
      .from('user_settings')
      .select('access_token, phone_number_id, api_version, access_token_added')
      .eq('id', user.id)
      .single();

    if (settingsError) {
      console.error('User settings error:', settingsError);
      return NextResponse.json(
        { error: 'WhatsApp credentials not configured. Please complete setup.', details: settingsError.message },
        { status: 400 }
      );
    }

    if (!settings) {
      console.error('No user settings found for user:', user.id);
      return NextResponse.json(
        { error: 'WhatsApp credentials not configured. Please complete setup.' },
        { status: 400 }
      );
    }

    if (!settings.access_token_added || !settings.access_token || !settings.phone_number_id) {
      console.error('WhatsApp API credentials not configured for user:', user.id);
      return NextResponse.json(
        { error: 'WhatsApp Access Token not configured. Please complete setup.' },
        { status: 400 }
      );
    }

    const accessToken = settings.access_token;
    const phoneNumberId = settings.phone_number_id;
    const apiVersion = settings.api_version || 'v23.0';

    // Prepare WhatsApp API request
    const whatsappApiUrl = `https://graph.facebook.com/${apiVersion}/${phoneNumberId}/messages`;
    console.log('Using phone_number_id:', phoneNumberId);
    
    // Build message payload based on type
    const messageData = sendAsTemplate 
     ? {
         messaging_product: 'whatsapp',
         to: cleanPhoneNumber,
         type: 'template',
         template: {
           name: template,
           language: { code: 'en_US' }
         }
       }
     : {
         messaging_product: 'whatsapp',
         to: cleanPhoneNumber,
         type: 'text',
         text: {
           body: message
         }
       };
    // Send message via WhatsApp Cloud API using user-specific access token
    const whatsappResponse = await fetch(whatsappApiUrl, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(messageData),
    });

    const responseData = await whatsappResponse.json();

    console.log('WhatsApp response:', responseData);

    if (!whatsappResponse.ok) {
      console.error('WhatsApp API error:', responseData);
      return NextResponse.json(
        { 
          error: 'Failed to send message via WhatsApp API', 
          details: responseData 
        }, 
        { status: whatsappResponse.status }
      );
    }

    // Get the message ID from WhatsApp response
    const messageId = responseData.messages?.[0]?.id;
    const timestamp = new Date().toISOString();

    console.log('Message sent successfully via WhatsApp API:', messageId);

    // Prepare message object for database insertion
    // Match webhook schema: sender_id is phone number (who sent), receiver_id is user UUID (who received)
    const messageObject = {
      id: messageId || `outgoing_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
      sender_id: user.id, // Logged-in user is the sender
      receiver_id: cleanPhoneNumber, // Contact's phone number is the receiver
      content: message,
      timestamp: timestamp,
      is_sent_by_me: true,
      is_read: true, // Outgoing messages are already "read" by the sender
      message_type: sendAsTemplate ? 'template' : 'text',
      media_data: null // No media data for text messages
    };

    console.log('Storing message in database:', {
      id: messageObject.id,
      sender_id: messageObject.sender_id,
      receiver_id: messageObject.receiver_id,
      content: messageObject.content.substring(0, 50) + (messageObject.content.length > 50 ? '...' : ''),
      timestamp: messageObject.timestamp,
      message_type: messageObject.message_type
    });

    // Ensure the sender (business owner) exists in the users table before inserting
    // the message — the messages table has a FK on sender_id → users.id
    const { error: userUpdateError } = await supabase
      .from('users')
      .upsert([{
        id: user.id,
        name: user.user_metadata?.full_name || user.email || 'Unknown User',
        last_active: timestamp
      }], {
        onConflict: 'id'
      });

    if (userUpdateError) {
      console.error('Error upserting sender in users table:', userUpdateError);
    }

    // Store the sent message in our database
    const { data: insertedMessage, error: dbError } = await supabase
      .from('messages')
      .insert([messageObject])
      .select()
      .single();

    if (dbError) {
      console.error('Error storing sent message in database:', dbError);
      // Don't fail the request if database storage fails, message was already sent
    } else {
      console.log('Message stored successfully in database:', insertedMessage?.id);
    }

    // Return success response
    return NextResponse.json({
      success: true,
      messageId: messageObject.id,
      timestamp: timestamp,
      whatsappResponse: responseData,
      storedInDb: !dbError
    });

  } catch (error) {
    console.error('Error in send-message API:', error);
    return NextResponse.json(
      { 
        error: 'Internal server error', 
        message: error instanceof Error ? error.message : 'Unknown error' 
      }, 
      { status: 500 }
    );
  }
}

/**
 * GET handler for checking API status (now user-specific)
 */
export async function GET() {
  try {
    const supabase = await createClient();
    
    // Verify user authentication
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) {
      return NextResponse.json(
        { error: 'Unauthorized' },
        { status: 401 }
      );
    }

    // Get user's WhatsApp API credentials
    const { data: settings } = await supabase
      .from('user_settings')
      .select('access_token_added, api_version')
      .eq('id', user.id)
      .single();

    const isConfigured = settings?.access_token_added || false;
    const apiVersion = settings?.api_version || 'v23.0';
    
    return NextResponse.json({
      status: 'WhatsApp Send Message API',
      configured: isConfigured,
      version: apiVersion,
      timestamp: new Date().toISOString()
    });
  } catch {
    return NextResponse.json({
      status: 'WhatsApp Send Message API',
      configured: false,
      error: 'Failed to check configuration',
      timestamp: new Date().toISOString()
    });
  }
} 