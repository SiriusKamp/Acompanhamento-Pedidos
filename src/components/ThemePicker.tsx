import { Moon, Sun, Zap } from 'lucide-react';

export type Theme = 'light' | 'dark' | 'neon';

export const themeLabels: Record<Theme, string> = {
  light: 'Claro', dark: 'Escuro', neon: 'Neon',
};

export const themeOrder: Theme[] = ['light', 'dark', 'neon'];

export function ThemePicker({ theme, onChange }: {
  theme: Theme; onChange: (theme: Theme) => void;
}) {
  return <div className="theme-picker" role="group" aria-label="Tema da interface">
    {themeOrder.map((value, index) => {
      const Icon = [Sun, Moon, Zap][index];
      return <button key={value} type="button" className={theme === value ? 'active' : ''}
        aria-label={`Tema ${themeLabels[value]}`} aria-pressed={theme === value}
        title={`Tema ${themeLabels[value]}`} onClick={() => onChange(value)}>
        <Icon size={16} /><span>{themeLabels[value]}</span>
      </button>;
    })}
  </div>;
}
