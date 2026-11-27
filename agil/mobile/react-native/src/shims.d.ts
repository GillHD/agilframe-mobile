/**
 * Minimal ambient declarations used only for this package's build/typecheck.
 *
 * React Native and React are peer dependencies: the monorepo does not install
 * them (they belong to the consuming app), and `dist` never ships this file.
 * The names below intentionally mirror the real @types/react / react-native
 * surface so emitted `.d.ts` files resolve against the consumer's real types.
 */
declare module 'react' {
  export type ReactNode = unknown;

  export interface ReactElement {
    type: unknown;
    props: Record<string, unknown>;
    key: string | null;
  }

  export interface RefObject<T> {
    readonly current: T | null;
  }

  export interface MutableRefObject<T> {
    current: T;
  }

  export type Ref<T> = RefObject<T> | ((instance: T | null) => void) | null;

  export interface RefAttributes<T> {
    ref?: Ref<T>;
    key?: string | number;
  }

  export interface ForwardRefExoticComponent<P> {
    (props: P): ReactElement | null;
    displayName?: string;
  }

  export function createElement(
    type: unknown,
    props?: Record<string, unknown> | null,
    ...children: ReactNode[]
  ): ReactElement;

  export function forwardRef<T, P = {}>(
    render: (props: P, ref: Ref<T>) => ReactElement | null,
  ): ForwardRefExoticComponent<P & RefAttributes<T>>;

  export function useCallback<T extends (...args: any[]) => any>(
    callback: T,
    deps: readonly unknown[],
  ): T;

  export function useEffect(effect: () => void | (() => void), deps?: readonly unknown[]): void;

  export function useImperativeHandle<T>(
    ref: Ref<T> | undefined,
    init: () => T,
    deps?: readonly unknown[],
  ): void;

  export function useMemo<T>(factory: () => T, deps: readonly unknown[]): T;

  export function useRef<T>(initialValue: T): MutableRefObject<T>;

  export function useRef<T>(initialValue: T | null): MutableRefObject<T | null>;

  export function useState<T>(
    initialState: T | (() => T),
  ): [T, (value: T | ((previous: T) => T)) => void];
}

declare module 'react-native' {
  import type { ReactElement } from 'react';

  export type ViewStyle = Record<string, unknown>;
  export type StyleProp<T> = T | readonly T[] | null | undefined;

  export interface ViewProps {
    style?: StyleProp<ViewStyle>;
    testID?: string;
    children?: unknown;
    [key: string]: unknown;
  }

  export const View: (props: ViewProps) => ReactElement | null;
  export const Text: (props: ViewProps) => ReactElement | null;

  export const StyleSheet: {
    create<T extends Record<string, ViewStyle>>(styles: T): T;
  };

  export const Platform: {
    OS: string;
    Version: string | number;
  };

  export const PermissionsAndroid: {
    PERMISSIONS: {
      CAMERA: string;
      RECORD_AUDIO: string;
      [key: string]: string;
    };
    RESULTS: {
      GRANTED: string;
      DENIED: string;
      NEVER_ASK_AGAIN: string;
    };
    requestMultiple(permissions: readonly string[]): Promise<Record<string, string>>;
  };

  export const Linking: {
    openSettings(): Promise<void>;
    openURL(url: string): Promise<unknown>;
  };
}

declare module 'react-native-webview' {
  import type { ReactElement } from 'react';

  export interface WebViewMessageEvent {
    nativeEvent: {
      data: string;
      [key: string]: unknown;
    };
  }

  export interface WebViewProps {
    [key: string]: unknown;
  }

  export const WebView: (props: WebViewProps) => ReactElement | null;
  export default WebView;
}
