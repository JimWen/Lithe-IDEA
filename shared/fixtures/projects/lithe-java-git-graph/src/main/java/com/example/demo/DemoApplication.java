package com.example.demo;


public class DemoApplication {
    public static void main(String[] args) {
        System.out.println(new com.example.demo.user.UserService(
                new com.example.demo.user.UserRepository()).listUsers());
    }
}
