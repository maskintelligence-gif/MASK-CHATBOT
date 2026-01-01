# MASK-CHATBOT BY MASK INTELLIGENCE 
(MASKHOSTING.ONLINE)


I'll help you set up GitHub Actions to build an APK for your Flutter app. Here's a complete setup:

1. Create GitHub Actions Workflow File

Create a new file in your project: .github/workflows/build-apk.yml

```yaml
name: Build APK

on:
  push:
    branches: [ main, master ]
  pull_request:
    branches: [ main, master ]
  workflow_dispatch: # Allows manual triggering

jobs:
  build:
    runs-on: ubuntu-latest
    
    steps:
    - name: Checkout code
      uses: actions/checkout@v3

    - name: Setup Java
      uses: actions/setup-java@v3
      with:
        distribution: 'temurin'
        java-version: '17'

    - name: Setup Flutter
      uses: subosito/flutter-action@v2
      with:
        flutter-version: '3.19.0' # Use your Flutter version
        channel: 'stable'
        cache: true
        cache-key: flutter-apk-cache

    - name: Install Flutter dependencies
      run: flutter pub get

    - name: Verify Flutter installation
      run: flutter doctor

    - name: Build APK
      env:
        GROQ_API_KEY: ${{ secrets.GROQ_API_KEY }}
      run: |
        flutter build apk \
          --release \
          --dart-define=GROQ_API_KEY=$GROQ_API_KEY \
          --split-per-abi

    - name: Upload APK artifacts
      uses: actions/upload-artifact@v3
      with:
        name: apk-artifacts
        path: build/app/outputs/flutter-apk/
        retention-days: 7

    - name: Create Release (Optional)
      if: github.event_name == 'push' && github.ref == 'refs/heads/main' || github.ref == 'refs/heads/master'
      uses: softprops/action-gh-release@v1
      with:
        tag_name: v1.0.${{ github.run_number }}
        name: Release v1.0.${{ github.run_number }}
        body: |
          Flutter APK Build ${{ github.sha }}
          
          Built by GitHub Actions run ${{ github.run_id }}
          
          **APK Files:**
          - app-arm64-v8a-release.apk (64-bit ARM)
          - app-armeabi-v7a-release.apk (32-bit ARM)
          - app-x86_64-release.apk (64-bit x86)
          - app-release.apk (Universal - all ABIs)
        draft: false
        prerelease: false
        files: |
          build/app/outputs/flutter-apk/app-*.apk
```

2. Create a Simpler Workflow (Alternative)

For a more straightforward setup:

```yaml
name: Flutter Build APK

on:
  push:
    branches: [ main ]
    tags:
      - 'v*'
  pull_request:
    branches: [ main ]
  workflow_dispatch:

env:
  FLUTTER_VERSION: '3.19.0'

jobs:
  build:
    runs-on: ubuntu-latest
    
    steps:
    - uses: actions/checkout@v3

    - name: Setup Flutter
      uses: subosito/flutter-action@v2
      with:
        flutter-version: ${{ env.FLUTTER_VERSION }}
        channel: 'stable'

    - name: Cache Flutter dependencies
      uses: actions/cache@v3
      with:
        path: /opt/hostedtoolcache/flutter
        key: flutter-${{ env.FLUTTER_VERSION }}-${{ hashFiles('pubspec.yaml') }}
        restore-keys: |
          flutter-${{ env.FLUTTER_VERSION }}-

    - name: Cache Pub dependencies
      uses: actions/cache@v3
      with:
        path: .dart_tool
        key: pub-${{ hashFiles('pubspec.lock') }}
        restore-keys: |
          pub-

    - name: Get dependencies
      run: flutter pub get

    - name: Analyze code
      run: flutter analyze

    - name: Run tests
      run: flutter test

    - name: Build APK
      env:
        GROQ_API_KEY: ${{ secrets.GROQ_API_KEY }}
      run: |
        echo "Building APK..."
        flutter build apk --release \
          --dart-define=GROQ_API_KEY=$GROQ_API_KEY \
          --split-per-abi
        
        echo "Build complete. Files created:"
        ls -la build/app/outputs/flutter-apk/

    - name: Upload APK
      uses: actions/upload-artifact@v3
      with:
        name: apk-files
        path: build/app/outputs/flutter-apk/
        if-no-files-found: error

    - name: Upload to Release (on tag)
      if: startsWith(github.ref, 'refs/tags/')
      uses: softprops/action-gh-release@v1
      with:
        files: build/app/outputs/flutter-apk/app-*.apk
```

3. Enhanced Workflow with Multiple Builds

For building both APK and AppBundle:

```yaml
name: Flutter CI/CD

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main ]
  release:
    types: [created]

jobs:
  test:
    runs-on: ubuntu-latest
    
    steps:
    - uses: actions/checkout@v3
    
    - name: Setup Flutter
      uses: subosito/flutter-action@v2
      with:
        flutter-version: '3.19.0'
    
    - name: Get dependencies
      run: flutter pub get
    
    - name: Run tests
      run: flutter test
    
    - name: Analyze code
      run: flutter analyze

  build-apk:
    needs: test
    runs-on: ubuntu-latest
    
    steps:
    - uses: actions/checkout@v3
    
    - name: Setup Flutter
      uses: subosito/flutter-action@v2
      with:
        flutter-version: '3.19.0'
    
    - name: Get dependencies
      run: flutter pub get
    
    - name: Build APK
      env:
        GROQ_API_KEY: ${{ secrets.GROQ_API_KEY }}
      run: |
        flutter build apk --release \
          --dart-define=GROQ_API_KEY=$GROQ_API_KEY \
          --split-per-abi
    
    - name: Upload APK artifacts
      uses: actions/upload-artifact@v3
      with:
        name: apk-build
        path: build/app/outputs/flutter-apk/
        retention-days: 30

  build-appbundle:
    needs: test
    runs-on: ubuntu-latest
    
    steps:
    - uses: actions/checkout@v3
    
    - name: Setup Java
      uses: actions/setup-java@v3
      with:
        distribution: 'temurin'
        java-version: '17'
    
    - name: Setup Flutter
      uses: subosito/flutter-action@v2
      with:
        flutter-version: '3.19.0'
    
    - name: Get dependencies
      run: flutter pub get
    
    - name: Build App Bundle
      env:
        GROQ_API_KEY: ${{ secrets.GROQ_API_KEY }}
      run: |
        flutter build appbundle --release \
          --dart-define=GROQ_API_KEY=$GROQ_API_KEY
    
    - name: Upload App Bundle
      uses: actions/upload-artifact@v3
      with:
        name: appbundle-build
        path: build/app/outputs/bundle/
        retention-days: 30
```

4. Set Up GitHub Secrets

Before running the workflow, you need to set up GitHub secrets:

1. Go to your GitHub repository
2. Click Settings → Secrets and variables → Actions
3. Click New repository secret
4. Add the following secrets:

```
Name: GROQ_API_KEY
Value: your_actual_groq_api_key_here
```

5. Update Your pubspec.yaml

Make sure your pubspec.yaml has proper configuration:

```yaml
name: groq_ai_chat
description: Groq AI Chat with Web Search
publish_to: 'none' # Remove this if you want to publish to pub.dev

version: 1.0.0+1

environment:
  sdk: '>=3.0.0 <4.0.0'
  flutter: ">=1.17.0"

dependencies:
  flutter:
    sdk: flutter
  
  # Core dependencies
  http: ^1.1.0
  provider: ^6.1.1
  flutter_markdown: ^0.6.15
  speech_to_text: ^6.6.0
  image_picker: ^1.0.4
  clipboard: ^0.1.3
  share_plus: ^7.2.1
  path_provider: ^2.1.0
  sqflite: ^2.3.0
  path: ^1.9.0

flutter:
  uses-material-design: true

  # To add assets to your application, add an assets section:
  # assets:
  #   - images/a_dot_burr.jpeg
  #   - images/a_dot_ham.jpeg

  # To add custom fonts to your application:
  # fonts:
  #   - family: Schyler
  #     fonts:
  #       - asset: fonts/Schyler-Regular.ttf
  #       - asset: fonts/Schyler-Italic.ttf
  #         style: italic
```

6. Create a README.md with Build Instructions

Add a build section to your README:

```markdown
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
```

GitHub Secrets

The build requires the following secrets in GitHub:

· GROQ_API_KEY: Your Groq API key

Download APK

APK files are available in the GitHub Actions artifacts after each successful build on the main branch.

```

## 7. **Optional: Fastlane Integration**

If you want to automate Google Play deployment:

```yaml
name: Deploy to Google Play

on:
  release:
    types: [published]

jobs:
  deploy:
    runs-on: ubuntu-latest
    
    steps:
    - uses: actions/checkout@v3
    
    - name: Setup Flutter
      uses: subosito/flutter-action@v2
      with:
        flutter-version: '3.19.0'
    
    - name: Setup Java
      uses: actions/setup-java@v3
      with:
        distribution: 'temurin'
        java-version: '17'
    
    - name: Build App Bundle
      env:
        GROQ_API_KEY: ${{ secrets.GROQ_API_KEY }}
      run: |
        flutter build appbundle --release \
          --dart-define=GROQ_API_KEY=$GROQ_API_KEY
    
    - name: Setup Fastlane
      uses: ruby/setup-ruby@v1
      with:
        ruby-version: '3.1'
    
    - name: Install Fastlane
      run: gem install fastlane
    
    - name: Deploy to Google Play
      env:
        SUPPLY_JSON_KEY_DATA: ${{ secrets.GOOGLE_PLAY_JSON_KEY }}
      run: |
        cd android
        fastlane supply \
          --aab ../build/app/outputs/bundle/release/app-release.aab \
          --track internal \
          --json_key "$SUPPLY_JSON_KEY_DATA"
```

8. Key Files Structure

Your project should have this structure:

```
groq_ai_chat/
├── .github/
│   └── workflows/
│       └── build-apk.yml
├── android/
│   ├── app/
│   │   └── build.gradle
│   └── local.properties
├── ios/
├── lib/
│   └── main.dart
├── pubspec.yaml
├── README.md
└── .gitignore
```

9. Important Notes

1. API Key Security: Never commit API keys to version control. Use GitHub Secrets.
2. Flutter Version: Update the Flutter version in the workflow to match your local version.
3. Build Variants: The workflow builds multiple APK variants for different architectures.
4. Artifact Retention: APKs are stored for 7-30 days (configurable).
5. Manual Trigger: You can manually trigger builds from GitHub Actions tab.

10. Testing the Workflow

1. Commit and push your changes
2. Go to your GitHub repository → Actions tab
3. You should see the workflow running
4. Once complete, download APKs from the artifacts section

This setup will automatically build APKs every time you push to the main branch, and you can download them directly from GitHub!
