import React, { useEffect } from 'react';
import { Text } from 'react-native';
import { NavigationContainer } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { CartProvider } from './src/data';
import { init } from './src/tugboat';
import HomeScreen from './src/screens/HomeScreen';
import CatalogScreen from './src/screens/CatalogScreen';
import ProfileScreen from './src/screens/ProfileScreen';
import BrowseScreen from './src/screens/BrowseScreen';
import CartScreen from './src/screens/CartScreen';
import ShippingScreen from './src/screens/ShippingScreen';
import PaymentScreen from './src/screens/PaymentScreen';
import ScrollPlaygroundScreen from './src/screens/ScrollPlaygroundScreen';
import NetworkScreen from './src/screens/NetworkScreen';

export type RootStackParams = {
  Tabs: undefined;
  Browse: undefined;
  Cart: undefined;
  Shipping: undefined;
  Payment: undefined;
  ScrollPlayground: undefined;
  Network: undefined;
};

const Stack = createNativeStackNavigator<RootStackParams>();
const Tab = createBottomTabNavigator();

const icon = (glyph: string) => () => <Text>{glyph}</Text>;

function Tabs() {
  return (
    <Tab.Navigator
      screenOptions={{ headerShown: false }}>
      <Tab.Screen name="Home" component={HomeScreen} options={{ tabBarIcon: icon('🏠'), tabBarButtonTestID: 'tab-home' }} />
      <Tab.Screen name="Catalog" component={CatalogScreen} options={{ tabBarIcon: icon('🛍'), tabBarButtonTestID: 'tab-catalog' }} />
      <Tab.Screen name="Profile" component={ProfileScreen} options={{ tabBarIcon: icon('👤'), tabBarButtonTestID: 'tab-profile' }} />
    </Tab.Navigator>
  );
}

export default function App() {
  useEffect(() => {
    init();
  }, []);
  return (
    <SafeAreaProvider>
      <CartProvider>
        <NavigationContainer>
          <Stack.Navigator>
            <Stack.Screen name="Tabs" component={Tabs} options={{ title: 'Tugboat Replay Demo' }} />
            <Stack.Screen name="Browse" component={BrowseScreen} options={{ title: 'Browse feed' }} />
            <Stack.Screen name="Cart" component={CartScreen} options={{ title: 'Your cart' }} />
            <Stack.Screen name="Shipping" component={ShippingScreen} />
            <Stack.Screen name="Payment" component={PaymentScreen} />
            <Stack.Screen name="ScrollPlayground" component={ScrollPlaygroundScreen} options={{ title: 'Scroll playground' }} />
            <Stack.Screen name="Network" component={NetworkScreen} />
          </Stack.Navigator>
        </NavigationContainer>
      </CartProvider>
    </SafeAreaProvider>
  );
}
