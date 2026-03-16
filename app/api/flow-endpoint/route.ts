import { NextResponse } from 'next/server';
import { NextRequest } from 'next/server';
import { createClient as createSupabaseClient } from '@supabase/supabase-js';

/**
 * WhatsApp Flows endpoint.
 *
 * WhatsApp calls this endpoint when a user interacts with a Flow embedded
 * in a WhatsApp message (sign-in, sign-up, etc.).
 *
 * IMPORTANT — Production checklist:
 *  1. Implement WhatsApp Flows payload decryption using your RSA private key
 *     (see https://developers.facebook.com/docs/whatsapp/flows/guides/implementingyourdataendpoint)
 *  2. Verify the X-Hub-Signature-256 header using META_APP_SECRET
 *  3. Encrypt the response payload before returning it to WhatsApp
 *
 * Until decryption/encryption is implemented this endpoint is NOT suitable
 * for production WhatsApp Flows — it only works for testing with unencrypted
 * payloads sent directly.
 */
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { screen_id, data } = body;

    if (screen_id === 'SIGN_IN') {
      const { email, password } = data || {};

      if (!email || !password) {
        return NextResponse.json({
          version: '7.2',
          screen: 'SIGN_IN',
          data: { email_error: 'Email and password are required.' },
        });
      }

      // Validate credentials against Supabase Auth using anon client
      const supabase = createSupabaseClient(
        process.env.NEXT_PUBLIC_SUPABASE_URL!,
        process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_OR_ANON_KEY!,
        { auth: { persistSession: false } }
      );

      const { error: authError } = await supabase.auth.signInWithPassword({ email, password });

      if (authError) {
        return NextResponse.json({
          version: '7.2',
          screen: 'SIGN_IN',
          data: { email_error: 'Invalid email or password.' },
        });
      }

      return NextResponse.json({
        version: '7.2',
        screen: 'SIGN_IN',
        data: { status_message: 'Sign in successful!' },
        action: { name: 'navigate', next_screen: 'SUCCESS_SCREEN' },
      });

    } else if (screen_id === 'SIGN_UP') {
      const { email, password, confirm_password } = data || {};

      if (!email || !password) {
        return NextResponse.json({
          version: '7.2',
          screen: 'SIGN_UP',
          data: { email_error: 'Email and password are required.' },
        });
      }

      if (password !== confirm_password) {
        return NextResponse.json({
          version: '7.2',
          screen: 'SIGN_UP',
          data: { password_error: 'Passwords do not match.' },
        });
      }

      // Create new user via Supabase anon client
      const supabase = createSupabaseClient(
        process.env.NEXT_PUBLIC_SUPABASE_URL!,
        process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_OR_ANON_KEY!,
        { auth: { persistSession: false } }
      );

      const { error: signUpError } = await supabase.auth.signUp({ email, password });

      if (signUpError) {
        return NextResponse.json({
          version: '7.2',
          screen: 'SIGN_UP',
          data: { email_error: signUpError.message },
        });
      }

      return NextResponse.json({
        version: '7.2',
        screen: 'SIGN_UP',
        data: { status_message: 'Account created! Please check your email to confirm.' },
      });
    }

    // Default response for unhandled screens
    return NextResponse.json({
      version: '7.2',
      screen: screen_id,
      data: { status_message: 'Received.' },
    });

  } catch (error) {
    console.error('Error processing flow data:', error);
    return NextResponse.json({
      version: '7.2',
      screen: 'SIGN_IN',
      data: { error_message: 'An unexpected error occurred. Please try again later.' },
    });
  }
}
