/**
 * Translate text using macOS Translation.framework.
 * Requires macOS 15+ with the target language pack installed.
 */
export declare function translateText(text: string, targetLang: string): Promise<string>;
