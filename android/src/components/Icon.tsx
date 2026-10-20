import React from 'react';
import Svg, { Circle, Path, Rect } from 'react-native-svg';

export type IconName =
  | 'phone'
  | 'laptop'
  | 'send'
  | 'inbox'
  | 'devices'
  | 'settings'
  | 'check'
  | 'x'
  | 'shield'
  | 'shieldCheck'
  | 'lock'
  | 'wifi'
  | 'wifiOff'
  | 'file'
  | 'image'
  | 'video'
  | 'music'
  | 'archive'
  | 'plus'
  | 'chevronRight'
  | 'download'
  | 'refresh'
  | 'alert'
  | 'trash'
  | 'bell'
  | 'folder'
  | 'info'
  | 'arrowUp'
  | 'arrowDown'
  | 'tile'
  | 'drop';

interface IconProps {
  name: IconName;
  size?: number;
  color: string;
  strokeWidth?: number;
}

/** Line icons on a 24×24 grid with round caps. Decorative: labels live on the parent. */
export function Icon({ name, size = 24, color, strokeWidth = 1.8 }: IconProps) {
  const s = {
    stroke: color,
    strokeWidth,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
    fill: 'none',
  };
  const dot = (cx: number, cy: number, r = 1) => (
    <Circle cx={cx} cy={cy} r={r} fill={color} />
  );
  let body: React.ReactNode;
  switch (name) {
    case 'phone':
      body = (
        <>
          <Rect x={6.5} y={2.5} width={11} height={19} rx={2.6} {...s} />
          <Path d="M10.5 18.5h3" {...s} />
        </>
      );
      break;
    case 'laptop':
      body = (
        <>
          <Rect x={4} y={5} width={16} height={11} rx={1.6} {...s} />
          <Path d="M2 19.5h20" {...s} />
        </>
      );
      break;
    case 'send':
      body = (
        <>
          <Path d="M21 3L10.2 13.8" {...s} />
          <Path d="M21 3l-6.6 18-4.2-7.2L3 9.6 21 3z" {...s} />
        </>
      );
      break;
    case 'inbox':
      body = (
        <>
          <Path d="M3 13h5l2 3h4l2-3h5" {...s} />
          <Path
            d="M5.6 5h12.8L21 13v6a1 1 0 01-1 1H4a1 1 0 01-1-1v-6l2.6-8z"
            {...s}
          />
        </>
      );
      break;
    case 'devices':
      body = (
        <>
          <Rect x={2} y={4} width={14} height={10} rx={1.5} {...s} />
          <Path d="M1.5 17.5H13" {...s} />
          <Rect x={16.5} y={8} width={6} height={12} rx={1.5} {...s} />
        </>
      );
      break;
    case 'settings':
      body = (
        <>
          <Path d="M4 6h9M18 6h2M4 12h3M11 12h9M4 18h11M19 18h1" {...s} />
          <Circle cx={15.5} cy={6} r={2.2} {...s} />
          <Circle cx={9} cy={12} r={2.2} {...s} />
          <Circle cx={17} cy={18} r={2.2} {...s} />
        </>
      );
      break;
    case 'check':
      body = <Path d="M5 12.5l4.5 4.5L19 7.5" {...s} />;
      break;
    case 'x':
      body = <Path d="M6.5 6.5l11 11M17.5 6.5l-11 11" {...s} />;
      break;
    case 'shield':
      body = (
        <Path
          d="M12 3l7 3v5.2c0 4.4-3 8.1-7 9.8-4-1.7-7-5.4-7-9.8V6l7-3z"
          {...s}
        />
      );
      break;
    case 'shieldCheck':
      body = (
        <>
          <Path
            d="M12 3l7 3v5.2c0 4.4-3 8.1-7 9.8-4-1.7-7-5.4-7-9.8V6l7-3z"
            {...s}
          />
          <Path d="M9 12l2.2 2.2L15.5 10" {...s} />
        </>
      );
      break;
    case 'lock':
      body = (
        <>
          <Rect x={5} y={10.5} width={14} height={10.5} rx={2.2} {...s} />
          <Path d="M8 10.5V7.8a4 4 0 018 0v2.7" {...s} />
        </>
      );
      break;
    case 'wifi':
      body = (
        <>
          <Path
            d="M2.5 8.8a14 14 0 0119 0M5.5 12.3a9.5 9.5 0 0113 0M8.6 15.8a5 5 0 016.8 0"
            {...s}
          />
          {dot(12, 19.3, 1.1)}
        </>
      );
      break;
    case 'wifiOff':
      body = (
        <>
          <Path d="M3 3l18 18" {...s} />
          <Path
            d="M8.6 15.8a5 5 0 016.8 0M5.5 12.3a9.5 9.5 0 014.2-2.3M18.5 12.3a9.6 9.6 0 00-2.1-1.5M2.5 8.8a14 14 0 013.4-2.4M21.5 8.8A14 14 0 0010.6 5"
            {...s}
          />
          {dot(12, 19.3, 1.1)}
        </>
      );
      break;
    case 'file':
      body = (
        <>
          <Path
            d="M14 3H7a2 2 0 00-2 2v14a2 2 0 002 2h10a2 2 0 002-2V8l-5-5z"
            {...s}
          />
          <Path d="M14 3v5h5" {...s} />
        </>
      );
      break;
    case 'image':
      body = (
        <>
          <Rect x={3} y={4} width={18} height={16} rx={2.2} {...s} />
          <Circle cx={8.5} cy={9.5} r={1.6} {...s} />
          <Path d="M21 15.5l-5-5L6 20" {...s} />
        </>
      );
      break;
    case 'video':
      body = (
        <>
          <Rect x={3} y={6} width={13} height={12} rx={2.2} {...s} />
          <Path d="M16 10.2l5-3v9.6l-5-3" {...s} />
        </>
      );
      break;
    case 'music':
      body = (
        <>
          <Path d="M9 18V5.5l11-2V16" {...s} />
          <Circle cx={6.5} cy={18} r={2.5} {...s} />
          <Circle cx={17.5} cy={16} r={2.5} {...s} />
        </>
      );
      break;
    case 'archive':
      body = (
        <>
          <Rect x={3} y={4} width={18} height={4.5} rx={1.2} {...s} />
          <Path d="M5 8.5V19a1 1 0 001 1h12a1 1 0 001-1V8.5M10 12.5h4" {...s} />
        </>
      );
      break;
    case 'plus':
      body = <Path d="M12 5v14M5 12h14" {...s} />;
      break;
    case 'chevronRight':
      body = <Path d="M9.5 6l6 6-6 6" {...s} />;
      break;
    case 'download':
      body = <Path d="M12 4v11M7 10.5l5 5 5-5M5 20h14" {...s} />;
      break;
    case 'refresh':
      body = (
        <>
          <Path d="M20 12a8 8 0 11-2.4-5.7" {...s} />
          <Path d="M20 4v5h-5" {...s} />
        </>
      );
      break;
    case 'alert':
      body = (
        <>
          <Circle cx={12} cy={12} r={9} {...s} />
          <Path d="M12 7.5v5.5" {...s} />
          {dot(12, 16.6)}
        </>
      );
      break;
    case 'info':
      body = (
        <>
          <Circle cx={12} cy={12} r={9} {...s} />
          <Path d="M12 11v5.5" {...s} />
          {dot(12, 7.8)}
        </>
      );
      break;
    case 'trash':
      body = (
        <Path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3" {...s} />
      );
      break;
    case 'bell':
      body = <Path d="M6 16v-5a6 6 0 0112 0v5l2 2H4l2-2zM10 21h4" {...s} />;
      break;
    case 'folder':
      body = (
        <Path
          d="M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2V7z"
          {...s}
        />
      );
      break;
    case 'arrowUp':
      body = <Path d="M12 19V5M6 11l6-6 6 6" {...s} />;
      break;
    case 'arrowDown':
      body = <Path d="M12 5v14M6 13l6 6 6-6" {...s} />;
      break;
    case 'tile':
      body = (
        <>
          <Rect x={3.5} y={3.5} width={7.5} height={7.5} rx={2} {...s} />
          <Rect x={13} y={3.5} width={7.5} height={7.5} rx={2} {...s} />
          <Rect x={3.5} y={13} width={7.5} height={7.5} rx={2} {...s} />
          <Rect x={13} y={13} width={7.5} height={7.5} rx={2} {...s} />
        </>
      );
      break;
    case 'drop':
      body = (
        <>
          <Path
            d="M12 2.8c3.6 4.1 6.3 7.5 6.3 10.7a6.3 6.3 0 01-12.6 0c0-3.2 2.7-6.6 6.3-10.7z"
            {...s}
          />
          <Path d="M9.4 14.2l2.6 2.6 2.6-2.6M12 16.8V10" {...s} />
        </>
      );
      break;
  }
  return (
    <Svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      accessible={false}
      importantForAccessibility="no-hide-descendants"
    >
      {body}
    </Svg>
  );
}

/** Picks an icon for a MIME type hint. */
export function iconForMime(mime: string | null | undefined): IconName {
  if (!mime) {
    return 'file';
  }
  if (mime.startsWith('image/')) {
    return 'image';
  }
  if (mime.startsWith('video/')) {
    return 'video';
  }
  if (mime.startsWith('audio/')) {
    return 'music';
  }
  if (/zip|tar|rar|7z|gzip|compressed/.test(mime)) {
    return 'archive';
  }
  return 'file';
}
