package com.example.demo.user;


import java.util.List;

public class UserService {
    private final UserRepository repository;

    public UserService(UserRepository repository) {
        this.repository = repository;
    }

    public List<UserRepository.UserSummary> listUsers() {
        return repository.findAll().stream().toList();
    }
}
