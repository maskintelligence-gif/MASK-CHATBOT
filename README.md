# MASK-CHATBOT BY MASK INTELLIGENCE 
(MASKHOSTING.ONLINE)

# Groq AI Chat with Web Search

## Building APK with GitHub Actions

This project uses GitHub Actions to automatically build APKs on push to main branch.

### Manual Build

To build locally:

```bash
# Set your API key
export GROQ_API_KEY="your_api_key_here"

# Build APK
flutter build apk --release --dart-define=GROQ_API_KEY=$GROQ_API_KEY

# Build App Bundle (for Google Play)
flutter build appbundle --release --dart-define=GROQ_API_KEY=$GROQ_API_KEY
