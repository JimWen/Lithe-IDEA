package com.example.demo.user;


import java.util.List;

public class UserController {
    private final UserService service;

    public UserController(UserService service) {
        this.service = service;
    }

    public List<UserRepository.UserSummary> list() {
        return service.listUsers();
    }

    public record UserQuery(String tenant) {}
}
