################################################################################
## CONSTANTS 
pwrmu <- 10
pwrsd <- 5
alpha <- .05
CRIT_95 <- 1.96 
CRIT_99 <- 2.58

################################################################################
## HELPER FUNCTIONS

sem <- function(x) {
  sd(x) / sqrt(length(x))
}

ci95.t <- function(x) {
  qt(.975, length(x) - 1) * sem(x)
}

pretty.p <- function(x) {
  as.character(signif(x, digits = 3))
}

input <- list(dataset_name = "Label advantage in concept learning",
              es_type = "d", ma_method = "REML", scatter_curve = "lm",
              forest_sort = "effects",
              #moderators = c("audio_condition", "response_mode"))
              #moderators = NULL)
              moderators = "mean_age")

shinyServer(function(input, output, session) {
  
  ##############################################################################
  # MODELS AND REACTIVES
  
  ########### DATA ###########
  
  categorical_mods <- reactive({
    if (is.null(input$moderators)) {
      return(NULL)
    }
    keep(input$moderators, function(mod) {
      # assumes all derived fields are non-categorical, which may change?
      !(mod %in% fields_derived$field) &&
        keep(fields, ~.x$field == mod)[[1]]$type %in% c("string", "options")
    })
  })
  
  mod_group <- reactive({
    if (length(categorical_mods())) {
      paste(categorical_mods(), collapse = "_")
    } else {
      "all_mod"
    }
  })
  
  combine_mods <- function(df, cols) {
    if (mod_group() != "all_mod" && length(cols) > 1) {
      df[[mod_group()]] <- do.call(paste, c(map(cols, ~df[[.x]]), sep = "\n"))
    }
    df
  }
  
  data <- reactive({
    req(input$dataset_name)
    all_data %>% filter(dataset == input$dataset_name)
  })
  
  mod_data <- reactive({
    dots <- if (is.null(input$moderators)) {
      NULL
    } else {
      sprintf("!is.na(%s)", input$moderators)
    }
    data() %>%
      filter_(.dots = dots) %>%
      combine_mods(categorical_mods())
  })
  
  table_data <- reactive({
    all_data %>%
      filter(dataset == input$table_dataset_name) %>%
      select(-long_cite, -dataset, -short_name, -filename, -all_mod)
  })
  
  output$dataset_table <- DT::renderDataTable(
    table_data(), style = "bootstrap", rownames = FALSE,
    options = list(scrollX = TRUE, autoWidth = TRUE, pageLength = 20)
  )
  
  ########### MODELS ###########
  
  es <- reactive({
    sprintf("%s_calc", input$es_type)
  })
  
  es_var <- reactive({
    sprintf("%s_var_calc", input$es_type)
  })
  
  model <- reactive({
    if (length(input$moderators) == 0) {
      no_mod_model()
    } else {
      mods <- paste(input$moderators, collapse = "+")
      rma_formula <- as.formula(sprintf("%s ~ %s", es(), mods))
      if (input$ma_method == "REML_mv") {
        metafor::rma.mv(rma_formula, V = mod_data()[[es_var()]],
                        random = ~ 1 | short_cite,
                        slab = short_cite, data = mod_data(),
                        method = "REML") 
      } else {
        metafor::rma(rma_formula, vi = mod_data()[[es_var()]],
                     slab = short_cite, data = mod_data(),
                     method = input$ma_method) 
      }
    }
  })
  
  no_mod_model <- reactive({
    if (input$ma_method == "REML_mv") {
      metafor::rma.mv(yi = data()[[es()]], V = data()[[es_var()]],
                      random = ~ 1 | data()[["short_cite"]],
                      slab = data()[["short_cite"]], 
                      method = "REML")
    } else {
      metafor::rma(yi = data()[[es()]], vi = data()[[es_var()]],
                   slab = data()[["short_cite"]], 
                   method = input$ma_method)
      
    }
  })
  
  ########### UI ELEMENTS ###########
  
  display_name <- function(fields) {
    sp <- gsub("_", " ", fields)
    paste0(toupper(substring(sp, 1, 1)), substring(sp, 2))
  }
  
  output$moderator_input <- renderUI({
    req(input$dataset_name)
    custom_mods <- datasets %>%
      filter(name == input$dataset_name) %>%
      .$moderators %>%
      unlist()
    mod_choices <- c("mean_age", "response_mode", "exposure_phase", custom_mods)
    valid_mod_choices <- mod_choices %>%
      set_names(display_name(.)) %>%
      keep(~length(unique(data()[[.x]])) > 1)
    checkboxGroupInput("moderators", label = "Moderators", valid_mod_choices,
                       inline = TRUE)
  })
  
  output$studies_box <- renderValueBox({
    valueBox(
      nrow(data()), "Conditions", icon = icon("list", lib = "glyphicon"),
      color = "red"
    )
  })
  
  output$effect_size_box <- renderValueBox({
    valueBox(
      sprintf("%.2f", no_mod_model()$b[,1][["intrcpt"]]), "Effect Size",
      icon = icon("record", lib = "glyphicon"),
      color = "red"
    )
  })
  
  output$effect_size_var_box <- renderValueBox({
    valueBox(
      sprintf("%.2f", no_mod_model()$se[1]), "Effect Size SE",
      icon = icon("resize-horizontal", lib = "glyphicon"),
      color = "red"
    )
  })
  
  output$effect_size_t2_box <- renderValueBox({
    valueBox(
      sprintf("%.2f", no_mod_model()$tau2[1]), "Tau^2",
      icon = icon("resize-full", lib = "glyphicon"),
      color = "red"
    )
  })
  
  output$viz_boxes <- renderUI({
    if (!input$ma_method == "REML_mv") {
      list(
        valueBoxOutput("studies_box", width = 3),
        valueBoxOutput("effect_size_box", width = 3),
        valueBoxOutput("effect_size_var_box", width = 3),
        valueBoxOutput("effect_size_t2_box", width = 3))
    } else {
      list(
        valueBoxOutput("studies_box", width = 4),
        valueBoxOutput("effect_size_box", width = 4),
        valueBoxOutput("effect_size_var_box", width = 4))
    }
  })
  
  observeEvent(categorical_mods(), {
    if (!is.null(categorical_mods())) {
      updateSelectInput(session, "scatter_curve", selected = "lm")
    }
  })
  
  
  #############################################################################
  # PLOTS
  
  ########### SCATTER PLOT ###########
  
  scatter <- function() {
    req(input$scatter_curve)
    
    labels <- if (mod_group() == "all_mod") NULL else
      setNames(paste(mod_data()[[mod_group()]], "  "), mod_data()[[mod_group()]])
    
    guide <- if (mod_group() == "all_mod") FALSE else "legend"
    p <- ggplot(mod_data(), aes_string(x = "mean_age_months", y = es(),
                                       colour = mod_group())) +
      geom_jitter(aes(size = n), alpha = 0.5) +
      geom_hline(yintercept = 0, linetype = "dashed", color = "grey") +
      scale_colour_solarized(name = "", labels = labels, guide = guide) +
      scale_size_continuous(guide = FALSE) +
      xlab("\nMean Subject Age (Months)") +
      ylab("Effect Size\n")
    
    #curve <- if (is.null(categorical_mods())) input$scatter_curve else "lm"
    if (input$scatter_curve == "lm") {
      p + geom_smooth(aes_string(weight = sprintf("1 / %s", es_var())),
                      method = "lm", se = FALSE)
    } else if (input$scatter_curve == "loess") {
      p + geom_smooth(aes_string(weight = sprintf("1 / %s", es_var())),
                      method = "loess", se = FALSE, span = 1)
    }
    
  }
  
  output$scatter <- renderPlot(scatter())
  
  output$longitudinal <- reactive({
    req(input$dataset_name)
    filter(datasets, name == input$dataset_name)$longitudinal
  })
  
  outputOptions(output, "longitudinal", suspendWhenHidden = FALSE)
  
  ########### VIOLIN PLOT ###########
  
  violin <- function() {
    plt_data <- mod_data()
    mod_factor <- factor(plt_data[[mod_group()]])
    plt_data[[mod_group()]] <- factor(plt_data[[mod_group()]],
                                      levels = rev(levels(mod_factor)))
    plt <- ggplot(plt_data, aes_string(x = mod_group(), y = es(),
                                       colour = mod_group())) +
      coord_flip() +
      geom_violin() +
      geom_jitter(height = 0) +
      geom_hline(yintercept = 0, linetype = "dashed", color = "grey") +
      scale_colour_solarized(name = "", guide = FALSE) +
      xlab("") +
      ylab("Effect Size\n")
    if (mod_group() == "all_mod") {
      plt + theme(axis.ticks.y = element_blank())
    } else {
      plt
    }
  }
  
  output$violin <- renderPlot(
    violin(),
    height = function() length(unique(mod_data()[[mod_group()]])) * 90 + 70
  )
  
  ########### FOREST PLOT ###########
  
  forest <- function() {
    f <- fitted(model())
    p <- predict(model())
    
    forest_data <- data.frame(effects = as.numeric(model()$yi.f),
                              variances = model()$vi.f) %>%
      mutate(effects.cil = effects -
               qnorm(alpha / 2, lower.tail = FALSE) * sqrt(variances),
             effects.cih = effects +
               qnorm(alpha / 2, lower.tail = FALSE) * sqrt(variances),
             estimate = as.numeric(f),
             short_cite = names(f),
             estimate.cil = p$ci.lb,
             estimate.cih = p$ci.ub,
             inverse_vars = 1/variances,
             identity = 1) %>%
      left_join(mutate(mod_data(), short_cite = make.unique(short_cite))) %>%
      arrange_(.dots = list(sprintf("desc(%s)", input$forest_sort),
                            "desc(effects)")) %>%
      mutate(short_cite = factor(short_cite, levels = short_cite))
    
    labels <- if (mod_group() == "all_mod") NULL else
      setNames(paste(mod_data()[[mod_group()]], "  "),
               mod_data()[[mod_group()]])
    guide <- if (mod_group() == "all_mod") FALSE else "legend"
    
    qplot(short_cite, effects, ymin = effects.cil, ymax = effects.cih,
          geom = "linerange",
          data = forest_data) +
      geom_point(aes(y = effects, size = inverse_vars)) +
      geom_pointrange(aes_string(x = "short_cite", y = "estimate",
                                 ymin = "estimate.cil", ymax = "estimate.cih",
                                 colour = mod_group()), 
                      pch = 17) +
      geom_hline(yintercept = 0, linetype = "dashed", color = "grey") +
      coord_flip() +
      scale_size_continuous(guide = FALSE) +
      scale_colour_solarized(name = "", labels = labels, guide = guide) +
      xlab("") +
      ylab("Effect Size")
  }
  
  forest_summary <- function() {
    pred_data <- data.frame(predictor = names(coef(model())),
                            coef = coef(model()),
                            ci.lb = summary(model())$ci.lb,
                            ci.ub = summary(model())$ci.ub)
    
    predictors <- data_frame(moderator = "", value = "", predictor = "intrcpt",
                             print_predictor = "intercept")
    if (!is.null(categorical_mods()) && length(categorical_mods())) {
      mod_vals <- map_df(categorical_mods(),
                         ~data_frame(moderator = .x,
                                     value = unique(mod_data()[[.x]]))) %>%
        mutate(predictor = paste0(moderator, value),
               print_predictor = sprintf("%s: %s", moderator, value))
      predictors <- predictors %>%
        bind_rows(mod_vals)
    }
    if ("mean_age" %in% input$moderators) {
      predictors <- predictors %>%
        bind_rows(data_frame(moderator = "", value = "", predictor = "mean_age",
                             print_predictor = "mean_age"))
    }
    pred_data %>% left_join(predictors) %>%
      ggplot(aes(x = print_predictor, y = coef, ymin = ci.lb,
                 ymax = ci.ub)) +
      geom_pointrange() +
      coord_flip() +
      xlab("") +
      ylab("Effect Size") +
      geom_hline(yintercept = 0, linetype = "dashed", color = "grey")
  }
  
  output$forest <- renderPlot(forest(),
                              height = function() nrow(mod_data()) * 10 + 100)
  
  output$forest_summary <- renderPlot(forest_summary(),
                                      height = 200)
  
  output$forest_summary_text <- renderPrint({
    summary(model())
  })
  
  ########### FUNNEL PLOT ###########
  
  funnel <- function() {
    if (length(input$moderators) == 0) {
      d <- data_frame(se = sqrt(model()$vi), es = model()$yi)
      center <- mean(d$es)
      xlabel <- "\nEffect Size"
      ylabel <- "Standard Error\n"
    } else {
      r <- rstandard(model())
      d <- data_frame(se = r$se, es = r$resid)
      center <- 0
      xlabel <- "\nResidual Effect Size"
      ylabel <- "Residual Standard Error\n"
    }
    d[[mod_group()]] <- mod_data()[[mod_group()]]
    
    lower_lim <- max(d$se) + .05 * max(d$se)
    funnel95 <- data.frame(x = c(center - lower_lim * CRIT_95, center,
                                 center + lower_lim * CRIT_95),
                           y = c(-lower_lim, 0, -lower_lim))
    
    left_lim99 <- ifelse(center - lower_lim * CRIT_99 < min(d$es),
                         center - lower_lim * CRIT_99,
                         min(d$es))
    right_lim99 <- ifelse(center + lower_lim * CRIT_99 > max(d$es),
                          center + lower_lim * CRIT_99,
                          max(d$es))
    funnel99 <- data.frame(x = c(center - lower_lim * CRIT_99, center,
                                 center + lower_lim * CRIT_99),
                           y = c(-lower_lim, 0, -lower_lim))
    
    labels <- if (mod_group() == "all_mod") NULL else
      setNames(paste(mod_data()[[mod_group()]], "  "),
               mod_data()[[mod_group()]])
    guide <- if (mod_group() == "all_mod") FALSE else "legend"
    
    ggplot(d, aes(x = es, y = -se)) +
      scale_colour_solarized(name = "", labels = labels, guide = guide) +
      scale_x_continuous(limits = c(left_lim99, right_lim99)) +
      scale_y_continuous(labels = function(x){abs(x)}) +
      geom_polygon(aes(x = x, y = y), data = funnel95, alpha = .5,
                   fill = "white") +
      geom_polygon(aes(x = x, y = y), data = funnel99, alpha = .5,
                   fill = "white") +
      geom_vline(xintercept = center, linetype = "dotted", color = "black") +
      geom_vline(xintercept = 0, linetype = "dashed", color = "grey") +
      geom_point(aes_string(colour = mod_group())) +
      xlab(xlabel) +
      ylab(ylabel) +
      geom_text(x = center + lower_lim * CRIT_95 / 2,
                y = -lower_lim + lower_lim / 30, #family = font,
                label = "p < .05", vjust = "bottom", hjust = "center") +
      geom_text(x = (center + lower_lim * CRIT_95) + (lower_lim * CRIT_99 - lower_lim * CRIT_95) / 2,
                y = -lower_lim + lower_lim / 30, #family = font,
                label = "p < .01", vjust = "bottom", hjust = "center") +
      theme(panel.background = element_rect(fill = "grey"),
            panel.grid.major =  element_line(colour = "darkgrey", size = 0.2),
            panel.grid.minor =  element_line(colour = "darkgrey", size = 0.5))
  }
  
  output$funnel <- renderPlot(funnel())
  output$funnel_test <- renderText({
    funnel_test <- metafor::regtest(model())
    sprintf("Regression test for funnel plot asymmetry: z = %.3g, p = %.3g.
            Interpret with caution due to the possible presence of confounding
            moderators.", funnel_test$zval, funnel_test$pval)
  })
  
  
  #############################################################################
  # DOWNLOAD HANDLERS
  
  plot_download_handler <- function(plot_name, plot_fun) {
    downloadHandler(
      filename = function() {
        sprintf("%s [%s].pdf", input$dataset_name, plot_name)
      },
      content = function(file) {
        cairo_pdf(file, width = 10, height = 7)
        print(plot_fun())
        dev.off()
      }
    )
  }
  
  output$download_scatter <- plot_download_handler("scatter", scatter)
  output$download_violin <- plot_download_handler("violin", violin)
  output$download_funnel <- plot_download_handler("funnel", funnel)
  output$download_forest <- plot_download_handler("forest", forest)
  output$download_power <- plot_download_handler("power", power)
  
  output$download_data <- downloadHandler(
    filename = function() sprintf("%s.csv", input$dataset_name),
    content = function(file) {
      readr::write_csv(data(), file)
    }
  )
  
  output$table_download_data <- downloadHandler(
    filename = function() sprintf("%s.csv", input$table_dataset_name),
    content = function(file) {
      readr::write_csv(table_data(), file)
    }
  )
  
  #############################################################################
  # POWER ANALYSIS
  
  conds <- reactive({
    if (input$control) {
      groups <- factor(c("Experimental","Control",
                         levels = c("Experimental", "Control")))
    } else {
      groups <- factor("Experimental")
    }
    expand.grid(group = groups,
                condition = factor(c("Longer looking predicted",
                                     "Shorter looking predicted"))) %>%
      group_by(group, condition)
  })
  
  ########### DATA ###########
  pwrdata <- reactive({
    all_data %>% filter(dataset == input$dataset_name_pwr)
  })
  
  ########### PWR MODEL ###########
  pwr_no_mod_model <- reactive({
    metafor::rma(d_calc, vi = d_var_calc, slab = as.character(study_ID),
                 data = pwrdata(), method = "REML")
  })
  
  pwrmodel <- reactive({
    if (length(input$pwr_moderators) == 0) {
      pwr_no_mod_model()
    } else {
      mods <- paste(input$pwr_moderators, collapse = "+")
      metafor::rma(as.formula(paste("d_calc ~", mods)), vi = d_var_calc,
                   slab = as.character(study_ID), data = pwrdata(),
                   method = "REML")
    }
  })
  
  ########### MODERATOR CHOICE #############
  
  pwr_mod_group <- reactive({
    if (length(input$pwr_moderators) == 0) {
      "all_mod"
    } else if ("response_mode" %in% input$pwr_moderators &
               "exposure_phase" %in% input$pwr_moderators) {
      "response_mode_exposure_phase"
    } else if ("response_mode" %in% input$pwr_moderators) {
      "response_mode"
    } else if ("exposure_phase" %in% input$pwr_moderators) {
      "exposure_phase"
    } else if ("mean_age" %in% input$pwr_moderators) {
      "all_mod"
    }
  })
  
  output$pwr_moderator_input <- renderUI({
    mod_choices <- list("Age" = "mean_age_months",
                        "Response mode" = "response_mode",
                        "Exposure phase" = "exposure_phase")
    valid_mod_choices <- mod_choices %>%
      keep(~length(unique(pwrdata()[[.x]])) > 1)
    
    # remove age moderator in longitudinal
    if (filter(datasets, name == input$dataset_name_pwr)$longitudinal) {
      valid_mod_choices <- valid_mod_choices %>%
        keep(~.x != "mean_age_months")
    }
    
    checkboxGroupInput("pwr_moderators", label = "Moderators",
                       valid_mod_choices,
                       inline = TRUE)
  })
  
  ########### RENDER UI FOR MODERATOR CHOICES #############
  output$pwr_moderator_choices <- renderUI({
    uis <- list()
    
    if (any(input$pwr_moderators == "mean_age_months")) {
      uis <- c(uis, list(
        sliderInput("pwr_age_months",
                    "Age of experimental participants",
                    min = 0, max = ceiling(max(pwrdata()$mean_age_months)),
                    value = round(mean(pwrdata()$mean_age_months)),
                    step = 1)
      ))
    }
    
    if (any(input$pwr_moderators == "response_mode")) {
      uis <- c(uis, list(
        selectInput("pwr_response_mode",
                    "Response mode",
                    choices = unique(pwrdata()$response_mode))
      ))
    }
    
    if (any(input$pwr_moderators == "exposure_phase")) {
      uis <- c(uis, list(
        selectInput("pwr_exposure_phase",
                    "Exposure phase",
                    choices = unique(pwrdata()$exposure_phase))
      ))
    }
    
    return(uis)
  })
  
  ########### POWER COMPUTATIONS #############
  
  # this is awful because RMA makes factors and dummy-codes them, so newpred
  # needs to have this structure.
  d_pwr <- reactive({
    if (length(input$pwr_moderators > 0)) {
      newpred_mat <- matrix(nrow = 0, ncol = 0)
      
      if (any(input$pwr_moderators == "mean_age_months")) {
        req(input$pwr_age_months)
        newpred_mat <- c(newpred_mat, input$pwr_age_months)
      }
      
      if (any(input$pwr_moderators == "response_mode")) {
        req(input$pwr_response_mode)
        
        f_response_mode <- factor(pwrdata()$response_mode)
        n <- length(levels(f_response_mode))
        
        response_pred <- rep(0, n)
        pred_seq <- seq(1:n)[levels(f_response_mode) == input$pwr_response_mode]
        response_pred[pred_seq] <- 1
        
        # remove intercept
        response_pred <- response_pred[-1]
        
        newpred_mat <- c(newpred_mat, response_pred)
      }
      
      if (any(input$pwr_moderators == "exposure_phase")) {
        req(input$pwr_exposure_phase)
        
        f_exp_phase <- factor(pwrdata()$exposure_phase)
        n <- length(levels(f_exp_phase))
        
        exposure_pred <- rep(0, n)
        exposure_pred[seq(1:n)[levels(fep) == input$pwr_exposure_phase]] <- 1
        
        # remove intercept
        exposure_pred <- exposure_pred[-1]
        
        newpred_mat <- c(newpred_mat, exposure_pred)
      }
      
      predict(pwrmodel(), newmods = newpred_mat)$pred
    } else {
      # special case when there are no predictors, predict doesn't work
      pwrmodel()$b[,1][["intrcpt"]]
    }
  })
  
  pwr_80 <- reactive({
    pwr::pwr.p.test(h = d_pwr(),
                    sig.level = .05,
                    power = .8)$n
  })
  
  ## now do the actual power analysis plot
  output$power <- renderPlot({
    max_n <- min(max(60,
                     pwr::pwr.p.test(h = d_pwr(),
                                     sig.level = .05,
                                     power = .9)$n),
                 200)
    
    pwrs <- data.frame(ns = seq(5, max_n, 5),
                       ps = pwr::pwr.p.test(h = d_pwr(),
                                            n = seq(5, max_n, 5),
                                            sig.level = .05)$power)
    
    qplot(ns, ps, geom = c("point","line"),
          data = pwrs) +
      geom_hline(yintercept = .8, lty = 2) +
      geom_vline(xintercept = pwr_80(), lty = 3) +
      ylim(c(0,1)) +
      xlim(c(0,max_n)) +
      ylab("Power to reject the null at p < .05") +
      xlab("Number of participants (N)")
  })
  
  ### POWER BOXES
  output$power_d <- renderValueBox({
    valueBox(
      round(d_pwr(), digits = 2), "Effect Size", icon = icon("record", lib = "glyphicon"),
      color = "red"
    )
  })
  
  output$power_n <- renderValueBox({
    valueBox(
      if(pwr_80() < 200) {round(pwr_80(), digits = 2) } else { "> 200"}, "N for 80% power",
      icon = icon("list", lib = "glyphicon"),
      color = "red"
    )
  })
  
  ########### GENERATE DATA #############
  pwr_sim_data <- reactive({
    if (input$go | !input$go) {
      conds() %>%
        do(data.frame(
          looking.time = ifelse(
            rep(.$group == "Experimental" &
                  .$condition == "Longer looking predicted", input$N),
            rnorm(n = input$N,
                  mean = pwrmu + (input$d_pwr * pwrsd) / 2,
                  sd = pwrsd),
            rnorm(n = input$N,
                  mean = pwrmu - (input$d_pwr * pwrsd) / 2,
                  sd = pwrsd)
          )
        )
        )
    }
  })
  
  ########### MEANS FOR PLOTTING #############
  pwr_ms <- reactive({
    pwr_sim_data() %>%
      group_by(group, condition) %>%
      summarise(mean = mean(looking.time),
                ci = ci95.t(looking.time),
                sem = sem(looking.time)) %>%
      rename_("interval" = input$interval)
  })
  
  ########### POWER ANALYSIS - BAR GRAPH #############
  output$pwr_bar <- renderPlot({
    req(input$d_pwr)
    
    pos <- position_dodge(width = .25)
    
    ggplot(pwr_ms(), aes(x = group, y = mean, fill = condition,
                         colour = condition)) +
      geom_bar(position = pos,
               stat = "identity",
               width = .25) +
      geom_linerange(data = pwr_ms(),
                     aes(x = group, y = mean,
                         fill = condition,
                         ymin = mean - interval,
                         ymax = mean + interval),
                     position = pos,
                     colour = "black") +
      xlab("Group") +
      ylab("Simulated Looking Time") +
      ylim(c(0,20)) +
      scale_fill_solarized(name = "",
                           labels = setNames(paste(pwr_ms()$condition, "  "),
                                             pwr_ms()$condition)) +
      scale_colour_solarized(name = "",
                             labels = setNames(paste(pwr_ms()$condition, "  "),
                                               pwr_ms()$condition))
  })
  
  ########### POWER ANALYSIS - SCATTER PLOT #############
  output$pwr_scatter <- renderPlot({
    req(input$d_pwr)
    
    pos <- position_jitterdodge(jitter.width = .1,
                                dodge.width = .25)
    
    ggplot(pwr_sim_data(),
           aes(x = group, y = looking.time, fill = condition,
               colour = condition)) +
      geom_point(position = pos) +
      geom_linerange(data = pwr_ms(),
                     aes(x = group, y = mean,
                         fill = condition,
                         ymin = mean - interval,
                         ymax = mean + interval),
                     position = pos,
                     size = 2,
                     colour = "black") +
      xlab("Group") +
      ylab("Looking Time") +
      ylim(c(0, ceiling(max(pwr_sim_data()$looking.time) / 5) * 5))
  })
  
  
  ########### STATISTICAL TEST OUTPUTS #############
  output$stat <- renderText({
    
    longer_exp <- filter(pwr_sim_data(),
                         condition == "Longer looking predicted",
                         group == "Experimental")$looking.time
    shorter_exp <- filter(pwr_sim_data(),
                          condition == "Shorter looking predicted",
                          group == "Experimental")$looking.time
    p.e <- t.test(longer_exp, shorter_exp, paired = TRUE)$p.value
    
    stat.text <- paste("A t test of the experimental condition is ",
                       ifelse(p.e > .05, "non", ""),
                       "significant at p = ",
                       pretty.p(p.e),
                       ". ",
                       sep = "")
    
    if (input$control) {
      
      longer_ctl <- filter(pwr_sim_data(),
                           condition == "Longer looking predicted",
                           group == "Control")$looking.time
      shorter_ctl <- filter(pwr_sim_data(),
                            condition == "Shorter looking predicted",
                            group == "Control")$looking.time
      p.c <- t.test(longer_ctl, shorter_ctl, paired = TRUE)$p.value
      
      a <- anova(lm(looking.time ~ group * condition, data = pwr_sim_data()))
      
      return(paste(stat.text,
                   "A t test of the control condition is ",
                   ifelse(p.c > .05, "non", ""),
                   "significant at p = ",
                   pretty.p(p.c),
                   ". An ANOVA ",
                   ifelse(a$"Pr(>F)"[3] < .05,
                          "shows a", "does not show a"),
                   " significant interaction at p = ",
                   pretty.p(a$"Pr(>F)"[3]),
                   ".",
                   sep = ""))
    }
    
    return(stat.text)
  })
  
  
  #############################################################################
  # SPECIFICATION TABLES
  
  get_property <- function(property, property_fun = function(x) x) {
    map_chr(fields, function(entry) {
      if (property %in% names(entry) && !is.null(entry[[property]]))
        property_fun(entry[[property]])
      else ""
    })
  }
  
  process_options <- function(options) {
    if (class(options) == "list") {
      opts <- names(unlist(options, recursive = FALSE))
    } else {
      opts <- options
    }
    paste(map_chr(opts, ~sprintf("<code>%s</code>", .x)), collapse = ", ")
  }
  fields_data <- data_frame(field = get_property("field"),
                            description = get_property("description"),
                            type = get_property("type"),
                            format = get_property("format"),
                            options = get_property("options", process_options),
                            required = get_property("required")) %>%
    unite(`format/options`, format, options, sep = "") %>%
    split(.$required) %>%
    map(~.x %>% select(-required))
  
  make_datatable <- function(df) {
    DT::renderDataTable(
      df, style = "bootstrap", rownames = FALSE, escape = FALSE,
      options = list(paging = FALSE, searching = FALSE,
                     dom = "t")
    )
  }
  
  output$req_table <- make_datatable(fields_data[["TRUE"]])
  output$opt_table <- make_datatable(fields_data[["FALSE"]])
  output$drv_table <- make_datatable(fields_derived)
  
})
  