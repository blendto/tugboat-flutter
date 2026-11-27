import React, { createContext, useContext, useState } from 'react';

export type Product = { name: string; price: number; category: string };

export const CATEGORIES = ['All', 'Bags', 'Accessories', 'Travel', 'Sale'];

export const PRODUCTS: Product[] = [
  { name: 'Canvas Weekender', price: 84, category: 'Bags' },
  { name: 'Travel Pouch', price: 28, category: 'Accessories' },
  { name: 'Leather Tote', price: 120, category: 'Bags' },
  { name: 'Packable Duffel', price: 65, category: 'Travel' },
  { name: 'Passport Wallet', price: 34, category: 'Accessories' },
  { name: 'Weekend Backpack', price: 98, category: 'Bags' },
  { name: 'Cable Organizer', price: 18, category: 'Accessories' },
  { name: 'Carry-on Spinner', price: 189, category: 'Travel' },
  { name: 'Outlet Sale Bundle', price: 49, category: 'Sale' },
  { name: 'Mini Crossbody', price: 56, category: 'Bags' },
];

const price = (name: string) => PRODUCTS.find(p => p.name === name)?.price ?? 0;

type CartState = {
  items: Record<string, number>;
  add: (name: string) => void;
  setQty: (name: string, qty: number) => void;
  clear: () => void;
  count: number;
  subtotal: number;
};

const CartContext = createContext<CartState>(null as unknown as CartState);
export const useCart = () => useContext(CartContext);

export function CartProvider({ children }: { children: React.ReactNode }) {
  const [items, setItems] = useState<Record<string, number>>({
    'Canvas Weekender': 1,
    'Travel Pouch': 2,
    'Leather Tote': 1,
  });
  const setQty = (name: string, qty: number) =>
    setItems(prev => {
      const next = { ...prev };
      if (qty <= 0) {
        delete next[name];
      } else {
        next[name] = qty;
      }
      return next;
    });
  const value: CartState = {
    items,
    add: name => setQty(name, (items[name] ?? 0) + 1),
    setQty,
    clear: () => setItems({}),
    count: Object.values(items).reduce((a, b) => a + b, 0),
    subtotal: Object.entries(items).reduce((sum, [n, q]) => sum + price(n) * q, 0),
  };
  return <CartContext.Provider value={value}>{children}</CartContext.Provider>;
}
